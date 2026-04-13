local M = {}

local DEFAULT_MODEL = "openai/gpt-4o"

local function extract_text_from_event(parsed)
  if type(parsed) ~= "table" then
    return nil
  end

  local choice = parsed.choices and parsed.choices[1]
  if not choice then
    return nil
  end

  -- Chat streaming shape: choices[1].delta.content = "..."
  if type(choice.delta) == "table" then
    if type(choice.delta.content) == "string" then
      return choice.delta.content
    end

    -- Some providers return content as a list of blocks.
    if type(choice.delta.content) == "table" then
      local out = {}
      for _, item in ipairs(choice.delta.content) do
        if type(item) == "string" then
          table.insert(out, item)
        elseif type(item) == "table" then
          if type(item.text) == "string" then
            table.insert(out, item.text)
          elseif type(item.value) == "string" then
            table.insert(out, item.value)
          end
        end
      end
      if #out > 0 then
        return table.concat(out)
      end
    end
  end

  -- Non-stream/fallback shape: choices[1].message.content = "..."
  if type(choice.message) == "table" and type(choice.message.content) == "string" then
    return choice.message.content
  end

  -- Legacy text completion shape
  if type(choice.text) == "string" then
    return choice.text
  end

  return nil
end

local function get_models_token()
  local env = os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN") or os.getenv("GITHUB_MODELS_TOKEN")
  if env and env ~= "" then
    return env
  end

  -- Fallback to GitHub CLI if available (`gh auth token`).
  local gh = vim.fn.executable("gh")
  if gh == 1 then
    local out = vim.fn.system({ "gh", "auth", "token" })
    if vim.v.shell_error == 0 then
      out = out:gsub("%s+$", "")
      if out ~= "" then
        return out
      end
    end
  end

  return nil
end

--- Start official GitHub authentication using GitHub CLI.
--- This uses documented account auth and then reuses `gh auth token`.
--- @param on_chunk function
--- @param on_done function
function M.login(on_chunk, on_done)
  if vim.fn.executable("gh") ~= 1 then
    on_chunk("⚠️ **GitHub CLI not found**: install `gh` and run `gh auth login -h github.com -w`.\n")
    on_chunk("Or set `GITHUB_TOKEN` manually with `models` scope.\n")
    on_chunk("Create token: https://github.com/settings/tokens\n")
    if on_done then on_done() end
    return
  end

  on_chunk("🔐 **Authentication required**. Opening terminal login flow...\n")
  on_chunk("Complete login in the terminal split, then submit your prompt again.\n")
  on_chunk("If chat still fails, create a PAT with `models` scope and export `GITHUB_TOKEN`.\n")

  vim.schedule(function()
    vim.cmd("botright 12split")
    vim.cmd("terminal gh auth login -h github.com -w")
  end)

  if on_done then on_done() end
end

--- Fetch response from the official GitHub Models API.
--- @param prompt string The user prompt
--- @param on_chunk function Callback for each text chunk
--- @param on_done function Callback when finished
function M.stream_response(prompt, on_chunk, on_done)
  local token = get_models_token()
  if not token then
    M.login(on_chunk, on_done)
    return
  end

  local payload = {
    model = DEFAULT_MODEL,
    messages = {
      { role = "system", content = "You are an AI programming assistant integrated into a Neovim editor." },
      { role = "user", content = prompt }
    },
    stream = true
  }

  local json_payload = vim.fn.json_encode(payload)
  
  -- Official endpoint from GitHub Models quickstart.
  local cmd = {
    "curl",
    "-N", "-s", "-L", "-X", "POST",
    "https://models.github.ai/inference/chat/completions",
    "-H", "Accept: application/vnd.github+json",
    "-H", "Authorization: Bearer " .. token,
    "-H", "X-GitHub-Api-Version: 2022-11-28",
    "-H", "Content-Type: application/json",
    "-d", json_payload
  }

  -- Launch async job to stream the JSON data
  local debug_output = {}
  local emitted_text = false
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data_lines)
      for _, line in ipairs(data_lines) do
        if line and line ~= "" then
          table.insert(debug_output, line)
          if line:match("^data: ") then
            local json_str = line:gsub("^data: ", "")
            if json_str == "[DONE]" then
              -- Expected end of stream
            else
              local ok, parsed = pcall(vim.fn.json_decode, json_str)
              if ok and parsed then
                if parsed.error then
                  on_chunk("\n⚠️ **API Error**: " .. vim.fn.json_encode(parsed.error) .. "\n")
                else
                  local text = extract_text_from_event(parsed)
                  if text and text ~= "" then
                    emitted_text = true
                    on_chunk(text)
                  end
                end
              else
                on_chunk("\n⚠️ **Parse Error**: Could not decode stream event.\n")
              end
            end
          else
            local ok, parsed = pcall(vim.fn.json_decode, line)
            if ok and parsed then
              if parsed.error then
                on_chunk("\n⚠️ **API Error**: " .. vim.fn.json_encode(parsed.error) .. "\n")
                on_chunk("Hint: GitHub Models requires a token with `models` scope.\n")
                on_chunk("Create one: https://github.com/settings/tokens\n")
                on_chunk("Then export it: `export GITHUB_TOKEN=...`\n")
                on_chunk("Hint: GitHub Models requires a token with `models` scope.\n")
                on_chunk("Create one: https://github.com/settings/tokens\n")
                on_chunk("Then export it: `export GITHUB_TOKEN=...`\n")
              else
                local text = extract_text_from_event(parsed)
                if text and text ~= "" then
                  emitted_text = true
                  on_chunk(text)
                else
                  on_chunk("\n⚠️ **Debug**: Received JSON without text payload.\n")
                end
              end
            else
              on_chunk("\n`" .. line .. "`\n")
            end
          end
        end
      end
    end,
    on_stderr = function(_, data_lines)
      for _, line in ipairs(data_lines) do
        if line and line ~= "" then
          on_chunk("\n⚠️ **Curl Error**: `" .. line .. "`\n")
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        on_chunk("\n⚠️ **Process exited with code**: `" .. tostring(code) .. "`\n")
      end
      if #debug_output == 0 then
        on_chunk("\n⚠️ **Error**: Received completely empty response from server.\n")
      elseif not emitted_text then
        on_chunk("\n⚠️ **No text generated**: Response arrived but contained no parsable text chunks.\n")
      end
      if on_done then on_done() end
    end,
  })
end

return M
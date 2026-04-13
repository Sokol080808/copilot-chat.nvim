local M = {}

local DEFAULT_MODEL = "openai/gpt-4o"
local INTENT_MODEL = "openai/gpt-4o-mini"

local function extract_text_from_event(parsed)
  if type(parsed) ~= "table" then
    return nil
  end

  local choice = parsed.choices and parsed.choices[1]
  if not choice then
    return nil
  end

  if type(choice.delta) == "table" then
    if type(choice.delta.content) == "string" then
      return choice.delta.content
    end

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

  if type(choice.message) == "table" and type(choice.message.content) == "string" then
    return choice.message.content
  end

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

  if vim.fn.executable("gh") == 1 then
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

local function extract_message_content(parsed)
  local choice = parsed and parsed.choices and parsed.choices[1]
  if not choice or type(choice.message) ~= "table" then
    return nil
  end

  local content = choice.message.content
  if type(content) == "string" then
    return content
  end

  if type(content) == "table" then
    local out = {}
    for _, part in ipairs(content) do
      if type(part) == "string" then
        table.insert(out, part)
      elseif type(part) == "table" and type(part.text) == "string" then
        table.insert(out, part.text)
      end
    end
    if #out > 0 then
      return table.concat(out)
    end
  end

  return nil
end

function M.detect_edit_intent(prompt)
  local token = get_models_token()
  if not token then
    return false
  end

  local payload = {
    model = INTENT_MODEL,
    messages = {
      {
        role = "system",
        content = "Classify whether the user asks to modify the currently open file. Reply with strict JSON only: {\"apply\":true} or {\"apply\":false}.",
      },
      {
        role = "user",
        content = prompt,
      },
    },
    stream = false,
    temperature = 0,
  }

  local cmd = {
    "curl",
    "-s", "-L", "-X", "POST",
    "https://models.github.ai/inference/chat/completions",
    "-H", "Accept: application/vnd.github+json",
    "-H", "Authorization: Bearer " .. token,
    "-H", "X-GitHub-Api-Version: 2022-11-28",
    "-H", "Content-Type: application/json",
    "-d", vim.fn.json_encode(payload),
  }

  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 or not out or out == "" then
    return false
  end

  local ok, parsed = pcall(vim.fn.json_decode, out)
  if not ok or not parsed or parsed.error then
    return false
  end

  local content = extract_message_content(parsed)
  if not content then
    return false
  end

  local json_ok, verdict = pcall(vim.fn.json_decode, content)
  if json_ok and type(verdict) == "table" and type(verdict.apply) == "boolean" then
    return verdict.apply
  end

  return content:lower():find("true", 1, true) ~= nil
end

function M.login(on_chunk, on_done)
  if vim.fn.executable("gh") ~= 1 then
    on_chunk("⚠️ **GitHub CLI not found**: install `gh` and run `gh auth login -h github.com -w`.\n")
    on_chunk("Or set `GITHUB_TOKEN` manually with `models` scope.\n")
    on_chunk("Create token: https://github.com/settings/tokens\n")
    if on_done then
      on_done()
    end
    return
  end

  on_chunk("🔐 **Authentication required**. Opening terminal login flow...\n")
  on_chunk("Complete login in the terminal split, then submit your prompt again.\n")
  on_chunk("If chat still fails, create a PAT with `models` scope and export `GITHUB_TOKEN`.\n")

  vim.schedule(function()
    vim.cmd("botright 12split")
    vim.cmd("terminal gh auth login -h github.com -w")
  end)

  if on_done then
    on_done()
  end
end

function M.stream_response(prompt, on_chunk, on_done)
  local token = get_models_token()
  if not token then
    M.login(on_chunk, on_done)
    return
  end

  local messages = nil
  if type(prompt) == "table" then
    messages = prompt
  else
    messages = {
      { role = "system", content = "You are an AI programming assistant integrated into a Neovim editor." },
      { role = "user", content = prompt },
    }
  end

  local payload = {
    model = DEFAULT_MODEL,
    messages = messages,
    stream = true,
  }

  local cmd = {
    "curl",
    "-N", "-s", "-L", "-X", "POST",
    "https://models.github.ai/inference/chat/completions",
    "-H", "Accept: application/vnd.github+json",
    "-H", "Authorization: Bearer " .. token,
    "-H", "X-GitHub-Api-Version: 2022-11-28",
    "-H", "Content-Type: application/json",
    "-d", vim.fn.json_encode(payload),
  }

  local debug_output = {}
  local emitted_text = false
  local sse_buffer = ""
  local assistant_text = ""

  local function emit_api_error(parsed)
    if type(parsed) == "table" and parsed.error then
      on_chunk("\n⚠️ **API Error**: " .. vim.fn.json_encode(parsed.error) .. "\n")
      on_chunk("Hint: GitHub Models requires a token with `models` scope.\n")
      on_chunk("Create one: https://github.com/settings/tokens\n")
      on_chunk("Then export it: `export GITHUB_TOKEN=...`\n")
      return true
    end
    return false
  end

  local function handle_event_line(line)
    if not line or line == "" then
      return
    end

    if line:match("^data:") then
      local json_str = line:gsub("^data:%s*", "")
      if json_str == "" or json_str == "[DONE]" then
        return
      end

      local ok, parsed = pcall(vim.fn.json_decode, json_str)
      if ok and parsed then
        if emit_api_error(parsed) then
          return
        end

        local text = extract_text_from_event(parsed)
        if text and text ~= "" then
          emitted_text = true
          assistant_text = assistant_text .. text
          on_chunk(text)
        end
      end
      return
    end

    if line:match("^event:") or line:match("^id:") or line:match("^:") then
      return
    end

    local ok, parsed = pcall(vim.fn.json_decode, line)
    if ok and parsed then
      if emit_api_error(parsed) then
        return
      end

      local text = extract_text_from_event(parsed)
      if text and text ~= "" then
        emitted_text = true
        assistant_text = assistant_text .. text
        on_chunk(text)
      end
    end
  end

  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data_lines)
      for i, part in ipairs(data_lines) do
        if part then
          sse_buffer = sse_buffer .. part
          if i < #data_lines then
            sse_buffer = sse_buffer .. "\n"
          end
        end
      end

      while true do
        local newline_idx = sse_buffer:find("\n", 1, true)
        if not newline_idx then
          break
        end

        local line = sse_buffer:sub(1, newline_idx - 1):gsub("\r$", "")
        sse_buffer = sse_buffer:sub(newline_idx + 1)
        table.insert(debug_output, line)
        handle_event_line(line)
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
      if sse_buffer ~= "" then
        local line = sse_buffer:gsub("\r$", "")
        table.insert(debug_output, line)
        handle_event_line(line)
      end

      if code ~= 0 then
        on_chunk("\n⚠️ **Process exited with code**: `" .. tostring(code) .. "`\n")
      end
      if #debug_output == 0 then
        on_chunk("\n⚠️ **Error**: Received completely empty response from server.\n")
      elseif not emitted_text then
        on_chunk("\n⚠️ **No text generated**: Response arrived but contained no parsable text chunks.\n")
      end
      if on_done then
        on_done(assistant_text)
      end
    end,
  })
end

return M

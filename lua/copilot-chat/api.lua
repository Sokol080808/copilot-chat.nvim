local M = {}

local function uuid4()
  math.randomseed(os.time() + (vim.loop.hrtime() % 1000000))
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end))
end

function M.new_session_id()
  return uuid4()
end

function M.cli_available()
  return vim.fn.executable("copilot") == 1
end

local function decode_event(line)
  if not line or line == "" then
    return nil
  end
  local ok, parsed = pcall(vim.fn.json_decode, line)
  if not ok then
    return nil
  end
  return parsed
end

--- Stream a single prompt through the copilot CLI.
--- @param prompt string Plain text prompt.
--- @param session_id string UUID used for --resume so the CLI manages history.
--- @param callbacks table { on_chunk(text), on_event(event), on_error(text), on_done(final_text) }
--- @return number|nil job_id
function M.stream(prompt, session_id, callbacks)
  callbacks = callbacks or {}
  local on_chunk = callbacks.on_chunk or function() end
  local on_event = callbacks.on_event or function() end
  local on_error = callbacks.on_error or function() end
  local on_done = callbacks.on_done or function() end

  if not M.cli_available() then
    on_error("Copilot CLI not found. Install with: npm install -g @github/copilot")
    on_done("")
    return nil
  end

  local cmd = {
    "copilot",
    "-p", prompt,
    "--output-format", "json",
    "--allow-all-tools",
    "--no-color",
    "-s",
    "--resume=" .. session_id,
  }

  local stdout_buf = ""
  local stderr_buf = ""
  local final_text = ""
  local saw_auth_error = false

  local function handle_event(event)
    if not event or type(event) ~= "table" then
      return
    end

    on_event(event)

    if event.type == "assistant.message_delta" then
      local data = event.data or {}
      local delta = data.deltaContent
      if type(delta) == "string" and delta ~= "" then
        final_text = final_text .. delta
        on_chunk(delta)
      end
    elseif event.type == "assistant.message" then
      local data = event.data or {}
      if type(data.content) == "string" and data.content ~= "" then
        if final_text == "" then
          final_text = data.content
          on_chunk(data.content)
        end
      end
    elseif event.type == "result" then
      if event.exitCode and event.exitCode ~= 0 then
        on_error("copilot exited with code " .. tostring(event.exitCode))
      end
    end
  end

  local function drain_lines(buf, leftover_ok)
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      handle_event(decode_event(line))
    end
    if leftover_ok and buf ~= "" then
      handle_event(decode_event(buf))
      buf = ""
    end
    return buf
  end

  local function append_chunks(target, chunks)
    for i, part in ipairs(chunks) do
      if part then
        target = target .. part
        if i < #chunks then
          target = target .. "\n"
        end
      end
    end
    return target
  end

  return vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      stdout_buf = append_chunks(stdout_buf, data)
      stdout_buf = drain_lines(stdout_buf, false)
    end,
    on_stderr = function(_, data)
      stderr_buf = append_chunks(stderr_buf, data)
      for _, line in ipairs(data or {}) do
        if type(line) == "string" and line ~= "" then
          if line:lower():match("authentication") or line:lower():match("unauthorized") or line:lower():match("not.*logged.*in") then
            saw_auth_error = true
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      stdout_buf = drain_lines(stdout_buf, true)

      if exit_code ~= 0 then
        if saw_auth_error then
          on_error("Authentication required. Run :CopilotChatLogin or `copilot login` in your terminal.")
        else
          local trimmed = (stderr_buf or ""):gsub("^%s+", ""):gsub("%s+$", "")
          if trimmed ~= "" then
            on_error("copilot CLI error (exit " .. exit_code .. "):\n" .. trimmed)
          else
            on_error("copilot CLI exited with code " .. exit_code)
          end
        end
      end

      on_done(final_text)
    end,
  })
end

return M

local M = {}

math.randomseed(os.time() + (vim.loop.hrtime() % 0x7fffffff))

local function uuid4()
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
  local ok, parsed = pcall(vim.json.decode, line)
  if not ok then
    return nil
  end
  return parsed
end

local function looks_like_auth_error(line)
  local lower = line:lower()
  return lower:match("authentication")
      or lower:match("unauthorized")
      or lower:match("not.*logged.*in")
end

--- Stream a single prompt through the copilot CLI.
--- @param prompt string Plain text prompt.
--- @param session_id string UUID used for --resume so the CLI manages history.
--- @param callbacks table { on_chunk(text), on_error(text), on_done(final_text) }
--- @param opts table|nil { cwd = string, add_dirs = string[] }
--- @return number|nil job_id
function M.stream(prompt, session_id, callbacks, opts)
  callbacks = callbacks or {}
  opts = opts or {}
  local on_chunk = callbacks.on_chunk or function() end
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

  for _, dir in ipairs(opts.add_dirs or {}) do
    table.insert(cmd, "--add-dir")
    table.insert(cmd, dir)
  end

  local stdout_buf = ""
  local stderr_buf = ""
  local final_parts = {}
  local saw_auth_error = false

  local function handle_event(event)
    if not event or type(event) ~= "table" then
      return
    end

    if event.type == "assistant.message_delta" then
      local data = event.data or {}
      local delta = data.deltaContent
      if type(delta) == "string" and delta ~= "" then
        table.insert(final_parts, delta)
        on_chunk(delta)
      end
    elseif event.type == "assistant.message" then
      local data = event.data or {}
      if type(data.content) == "string" and data.content ~= "" and #final_parts == 0 then
        table.insert(final_parts, data.content)
        on_chunk(data.content)
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
      handle_event(decode_event(buf:sub(1, nl - 1)))
      buf = buf:sub(nl + 1)
    end
    if leftover_ok and buf ~= "" then
      handle_event(decode_event(buf))
      buf = ""
    end
    return buf
  end

  return vim.fn.jobstart(cmd, {
    cwd = opts.cwd,
    on_stdout = function(_, data)
      stdout_buf = stdout_buf .. table.concat(data, "\n")
      stdout_buf = drain_lines(stdout_buf, false)
    end,
    on_stderr = function(_, data)
      stderr_buf = stderr_buf .. table.concat(data, "\n")
      for _, line in ipairs(data or {}) do
        if type(line) == "string" and line ~= "" and looks_like_auth_error(line) then
          saw_auth_error = true
        end
      end
    end,
    on_exit = function(_, exit_code)
      stdout_buf = drain_lines(stdout_buf, true)

      if exit_code ~= 0 then
        if saw_auth_error then
          on_error("Authentication required. Run :CopilotChatLogin or `copilot login` in your terminal.")
        else
          local trimmed = vim.trim(stderr_buf or "")
          if trimmed ~= "" then
            on_error("copilot CLI error (exit " .. exit_code .. "):\n" .. trimmed)
          else
            on_error("copilot CLI exited with code " .. exit_code)
          end
        end
      end

      on_done(table.concat(final_parts))
    end,
  })
end

return M

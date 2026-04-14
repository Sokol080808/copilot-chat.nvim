local M = {}

function M.detect_edit_intent(prompt, context)
  local ctx = context or {}
  local context_text = "has_open_file=" .. tostring(ctx.has_open_file == true)
    .. "\nfile_path=" .. (ctx.file_path or "")
    .. "\nfiletype=" .. (ctx.filetype or "")

  local sys_prompt = "You classify whether a Neovim chat request should edit the current file. "
    .. "Use provided file context. If the user asks to write/implement/add/fix/refactor code and an open file exists, usually return true. "
    .. "Return false only for pure explanation/Q&A requests. "
    .. "Reply with strict JSON only: {\"apply\":true} or {\"apply\":false}."

  local full_prompt = sys_prompt .. "\n\nContext:\n" .. context_text .. "\n\nPrompt: " .. prompt .. "\n\nAnswer JSON:"

  local cmd = {
    "copilot",
    "-p", full_prompt,
    "--output-format", "json",
  }

  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 or not out or out == "" then
    return false
  end

  local lines = vim.split(out, "\n")
  local content = ""
  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, parsed = pcall(vim.fn.json_decode, line)
      if ok and parsed and parsed.type == "assistant.message" and parsed.data and parsed.data.content then
        content = parsed.data.content
        break
      end
    end
  end

  if not content or content == "" then
    return false
  end

  local json_ok, verdict = pcall(vim.fn.json_decode, content)
  if json_ok and type(verdict) == "table" and type(verdict.apply) == "boolean" then
    return verdict.apply
  end

  return content:lower():find("true", 1, true) ~= nil
end

function M.login(on_chunk, on_done)
  if vim.fn.executable("copilot") ~= 1 then
    on_chunk("⚠️ **Copilot CLI not found**: install with `npm install -g @github/copilot`.\n")
    if on_done then
      on_done()
    end
    return
  end
  on_chunk("🔐 **Authentication required**. Run `copilot login` in your terminal.\n")
  if on_done then
    on_done()
  end
end

function M.stream_response(prompt, on_chunk, on_done)
  if vim.fn.executable("copilot") ~= 1 then
    M.login(on_chunk, on_done)
    return
  end

  local query = ""
  if type(prompt) == "table" then
    local parts = {}
    for _, msg in ipairs(prompt) do
      table.insert(parts, msg.role:upper() .. ": " .. msg.content)
    end
    query = table.concat(parts, "\n\n")
  else
    query = prompt
  end

  local cmd = {
    "copilot",
    "-p", query,
    "--output-format", "json",
  }

  local sse_buffer = ""

  local function handle_event_line(line)
    if not line or line == "" then
      return
    end

    local ok, parsed = pcall(vim.fn.json_decode, line)
    if ok and parsed then
      if parsed.type == "assistant.message_delta" and parsed.data and parsed.data.deltaContent then
        if parsed.data.deltaContent ~= "" then
          on_chunk(parsed.data.deltaContent)
        end
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

        local line = sse_buffer:sub(1, newline_idx - 1)
        sse_buffer = sse_buffer:sub(newline_idx + 1)
        handle_event_line(line)
      end
    end,
    on_stderr = function(_, err_lines)
      for _, line in ipairs(err_lines) do
        if line and (line:match("Authentication required") or line:match("unauthorized")) then
          on_chunk("\n⚠️ Copilot CLI requires authentication. Run `copilot login` in your terminal.\n")
        end
      end
    end,
    on_exit = function(_, exit_code)
      if sse_buffer ~= "" then
        handle_event_line(sse_buffer)
      end
      if on_done then
        on_done()
      end
    end,
  })
end

return M

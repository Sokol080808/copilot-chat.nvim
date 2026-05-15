local api = require("copilot-chat.api")
local ui = require("copilot-chat.ui")
local diff = require("copilot-chat.diff")

local M = {}

M.config = {
  system_prompt = nil,
  edit_fence_tag = "UPDATE",
}

M.session_id = nil
M._first_turn = true
M._current_job = nil

local function ensure_session()
  if not M.session_id then
    M.session_id = api.new_session_id()
    M._first_turn = true
  end
end

local function build_user_message(prompt)
  if M._first_turn and M.config.system_prompt and M.config.system_prompt ~= "" then
    return M.config.system_prompt .. "\n\n" .. prompt
  end
  return prompt
end

local function send(prompt, on_text, on_done)
  ensure_session()

  local message = build_user_message(prompt)
  M._first_turn = false
  ui.set_busy(true)

  local stream_ui = on_text ~= nil
  if stream_ui then ui.begin_stream() end

  local on_chunk
  if on_text then
    on_chunk = function(chunk)
      vim.schedule(function() on_text(chunk) end)
    end
  end

  M._current_job = api.stream(message, M.session_id, {
    on_chunk = on_chunk,
    on_error = function(err)
      vim.schedule(function()
        ui.append_chat({ "", "> ⚠️ " .. err })
      end)
    end,
    on_done = function(final_text)
      vim.schedule(function()
        if stream_ui then ui.end_stream() end
        ui.set_busy(false)
        M._current_job = nil
        if on_done then on_done(final_text or "") end
      end)
    end,
  })
end

local function ensure_trailing_nl(s)
  if s == "" or s:sub(-1) == "\n" then return s end
  return s .. "\n"
end

local function diff_stats(old_text, new_text)
  -- Normalize trailing newline so vim.diff doesn't count "no newline at EOF"
  -- artifacts as edits to the last real line.
  local unified = vim.diff(ensure_trailing_nl(old_text), ensure_trailing_nl(new_text),
    { result_type = "unified", ctxlen = 0 })
  if not unified or unified == "" then return 0, 0 end
  local added, removed = 0, 0
  for line in (unified .. "\n"):gmatch("([^\n]*)\n") do
    local first = line:sub(1, 1)
    if first == "+" and line:sub(1, 3) ~= "+++" then
      added = added + 1
    elseif first == "-" and line:sub(1, 3) ~= "---" then
      removed = removed + 1
    end
  end
  return added, removed
end

local function short_path(path)
  if not path or path == "" then return "<unnamed>" end
  return vim.fn.fnamemodify(path, ":~:.")
end

local function source_file_buf()
  local buf = ui.get_source_buf()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil, "No source buffer found."
  end
  if vim.bo[buf].buftype ~= "" then
    return nil, "Active source buffer is not a file."
  end
  return buf, nil
end

local function extract_fence(text, tag)
  if not text or text == "" then return nil end
  local _, _, body = text:find("```" .. tag .. "\n(.-)\n```")
  if body then return body end
  local _, _, generic = text:find("```[%w%-_]*\n(.-)\n```")
  return generic
end

local function append_user_message(label, text)
  ui.append_chat({ "", "### " .. label, "" })
  ui.append_chat(vim.split(text, "\n", { plain = true }))
end

local function open_assistant_block()
  ui.append_chat({ "", "### Copilot", "" })
end

local function close_message_block()
  ui.append_chat({ "", "---", "" })
end

local function reject_if_busy()
  if not ui.is_busy() then return false end
  ui.append_chat({ "", "> ⚠️ A reply is still streaming. Wait or run :CopilotChatCancel.", "" })
  return true
end

local function submit_chat(prompt)
  if not prompt or vim.trim(prompt) == "" then return end
  if reject_if_busy() then return end

  append_user_message("You", prompt)
  open_assistant_block()
  ui.clear_input()

  send(prompt, ui.stream_chat, function()
    close_message_block()
  end)
end

local function submit_edit(prompt, range)
  if not prompt or vim.trim(prompt) == "" then return end
  if reject_if_busy() then return end

  local source_buf, err = source_file_buf()
  if not source_buf then
    ui.append_chat({ "", "> ⚠️ " .. err, "" })
    return
  end

  local path = vim.api.nvim_buf_get_name(source_buf)
  local label = short_path(path)
  local file_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local file_body = table.concat(file_lines, "\n")

  local selection = ""
  if range and range.start_line and range.end_line and range.end_line >= range.start_line then
    local sel_lines = vim.api.nvim_buf_get_lines(source_buf, range.start_line - 1, range.end_line, false)
    selection = table.concat(sel_lines, "\n")
  end

  local tag = M.config.edit_fence_tag or "UPDATE"
  local instructions = table.concat({
    "You are editing a file inside Neovim.",
    "Return the COMPLETE updated file content in a single fenced code block opening with ```" .. tag .. " and closing with ```.",
    "Do not add explanation outside the code block. Preserve the existing indentation style and only change what the request asks for — leave unrelated lines exactly as they are.",
    "",
    "Target file: " .. path,
    "",
    "Current file content:",
    "```",
    file_body,
    "```",
  }, "\n")

  if selection ~= "" then
    instructions = instructions .. "\n\nFocus on this selection (lines " .. range.start_line .. "-" .. range.end_line .. "):\n```\n" .. selection .. "\n```"
  end

  instructions = instructions .. "\n\nRequested change:\n" .. prompt

  append_user_message("You (edit)", prompt)
  ui.append_chat({ "", "> ✏️ Generating edit for `" .. label .. "`…" })
  ui.clear_input()

  -- on_text=nil: don't pour the regenerated file into chat.
  send(instructions, nil, function(full)
    local code = extract_fence(full, tag)
    if not code then
      ui.append_chat({ "", "> ⚠️ Edit failed: model did not return a fenced `" .. tag .. "` block." })
      close_message_block()
      return
    end

    local added, removed = diff_stats(file_body, code)
    if added == 0 and removed == 0 then
      ui.append_chat({ "", "> ℹ️ Model returned the file unchanged — nothing to preview." })
      close_message_block()
      return
    end

    diff.preview(source_buf, code,
      function() ui.append_chat({ "", "> ✅ Applied to `" .. label .. "`." }) end,
      function() ui.append_chat({ "", "> ↩️ Skipped." }) end
    )

    ui.append_chat({
      "",
      "> ✏️ Edit ready (+" .. added .. " / -" .. removed .. "). `:CopilotChatApply` to accept, `:CopilotChatSkip` to discard.",
    })
    close_message_block()
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local group = vim.api.nvim_create_augroup("CopilotChatPreviewResize", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function() diff.refresh() end,
  })
end

function M.open()  ui.open()  end
function M.close() ui.close() end
function M.toggle() ui.toggle() end
function M.focus_input() ui.focus_input() end

function M.ask()
  ui.open()
  ui.focus_input()
end

function M._submit_input()
  local text = ui.input_text()
  if vim.trim(text) == "" then return end
  submit_chat(text)
end

function M.send_prompt(prompt)
  ui.open()
  submit_chat(prompt)
end

function M.edit(prompt, range)
  ui.open()
  if not prompt or prompt == "" then
    prompt = ui.input_text()
  end
  submit_edit(prompt, range)
end

function M.apply_pending()
  local ok, err = diff.apply()
  if not ok then ui.append_chat({ "", "> " .. err, "" }) end
end

function M.skip_pending()
  local ok, err = diff.skip()
  if not ok then ui.append_chat({ "", "> " .. err, "" }) end
end

function M.cancel()
  if M._current_job then
    pcall(vim.fn.jobstop, M._current_job)
    M._current_job = nil
    ui.end_stream()
    ui.set_busy(false)
    ui.append_chat({ "", "> Cancelled.", "" })
  end
end

function M.new_session()
  if M._current_job then M.cancel() end
  diff.skip()
  M.session_id = api.new_session_id()
  M._first_turn = true
  ui.set_chat_lines({
    "# Copilot Chat",
    "",
    "(new session: " .. M.session_id .. ")",
    "",
    "---",
  })
end

function M.login()
  if not api.cli_available() then
    vim.notify("Copilot CLI not installed. Run: npm install -g @github/copilot", vim.log.levels.ERROR)
    return
  end
  vim.cmd("botright split | resize 15 | terminal copilot login")
  vim.cmd("startinsert")
end

return M

local api = vim.api

local INPUT_WINBAR_IDLE = "Copilot > prompt (C-s send / CR send / q close)"
local INPUT_WINBAR_BUSY = "Copilot is replying… (Esc to keep typing — submission disabled)"

local STREAM_FLUSH_MS = 30

local M = {
  chat_buf = nil,
  chat_win = nil,
  input_buf = nil,
  input_win = nil,
  source_buf = nil,
  busy = false,
  width = 60,
  input_height = 6,
  _streaming = false,
  _stream_pending = nil,
  _stream_timer = nil,
}

local CHAT_HEADER = {
  "# Copilot Chat",
  "",
  "Press <C-s> in insert mode (or <CR> in normal mode) inside the input box to send.",
  "",
  "---",
}

local COMMON_WIN_OPTS = {
  wrap = true,
  linebreak = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  winfixwidth = true,
}

local function set_win_opts(win, overrides)
  for name, value in pairs(COMMON_WIN_OPTS) do
    api.nvim_set_option_value(name, value, { win = win })
  end
  if overrides then
    for name, value in pairs(overrides) do
      api.nvim_set_option_value(name, value, { win = win })
    end
  end
end

local function make_chat_buffer()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  api.nvim_buf_set_name(buf, "[CopilotChat]")
  return buf
end

local function make_input_buffer()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  api.nvim_buf_set_name(buf, "[CopilotChatInput]")
  return buf
end

local function map(buf, mode, lhs, target)
  api.nvim_buf_set_keymap(buf, mode, lhs,
    "<cmd>lua require('copilot-chat')." .. target .. "()<CR>",
    { noremap = true, silent = true })
end

local function bind_input_keys(buf)
  api.nvim_buf_set_keymap(buf, "i", "<C-s>",
    "<Esc><cmd>lua require('copilot-chat')._submit_input()<CR>",
    { noremap = true, silent = true })
  map(buf, "n", "<CR>", "_submit_input")
  map(buf, "n", "q",    "close")
end

local function bind_chat_keys(buf)
  map(buf, "n", "q",    "close")
  map(buf, "n", "i",    "focus_input")
  map(buf, "n", "a",    "focus_input")
  map(buf, "n", "<CR>", "focus_input")
end

local function ensure_chat_buf()
  if not (M.chat_buf and api.nvim_buf_is_valid(M.chat_buf)) then
    M.chat_buf = make_chat_buffer()
    bind_chat_keys(M.chat_buf)
    M.set_chat_lines(CHAT_HEADER)
  end
end

local function ensure_input_buf()
  if not (M.input_buf and api.nvim_buf_is_valid(M.input_buf)) then
    M.input_buf = make_input_buffer()
    bind_input_keys(M.input_buf)
  end
end

function M.is_open()
  return M.chat_win and api.nvim_win_is_valid(M.chat_win)
end

function M.open()
  if M.is_open() then
    api.nvim_set_current_win(M.chat_win)
    return
  end

  local current_buf = api.nvim_get_current_buf()
  if current_buf ~= M.chat_buf and current_buf ~= M.input_buf then
    M.source_buf = current_buf
  end

  ensure_chat_buf()
  ensure_input_buf()

  vim.cmd("botright vsplit")
  M.chat_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.chat_win, M.chat_buf)
  api.nvim_win_set_width(M.chat_win, M.width)
  set_win_opts(M.chat_win, { foldcolumn = "0" })

  vim.cmd("belowright split")
  M.input_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.input_win, M.input_buf)
  api.nvim_win_set_height(M.input_win, M.input_height)
  set_win_opts(M.input_win, { winfixheight = true, winbar = INPUT_WINBAR_IDLE })

  M.scroll_chat_to_bottom()
  api.nvim_set_current_win(M.input_win)
  vim.cmd("startinsert")
end

function M.close()
  if M.input_win and api.nvim_win_is_valid(M.input_win) then
    pcall(api.nvim_win_close, M.input_win, true)
  end
  if M.chat_win and api.nvim_win_is_valid(M.chat_win) then
    pcall(api.nvim_win_close, M.chat_win, true)
  end
  M.chat_win = nil
  M.input_win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.focus_input()
  if not M.is_open() then
    M.open()
    return
  end
  if M.input_win and api.nvim_win_is_valid(M.input_win) then
    api.nvim_set_current_win(M.input_win)
    vim.cmd("startinsert")
  end
end

function M.scroll_chat_to_bottom()
  if not (M.chat_win and api.nvim_win_is_valid(M.chat_win)) then return end
  if not (M.chat_buf and api.nvim_buf_is_valid(M.chat_buf)) then return end
  local n = api.nvim_buf_line_count(M.chat_buf)
  pcall(api.nvim_win_set_cursor, M.chat_win, { n, 0 })
end

local function set_chat_modifiable(value)
  if M.chat_buf and api.nvim_buf_is_valid(M.chat_buf) then
    api.nvim_set_option_value("modifiable", value, { buf = M.chat_buf })
  end
end

local function with_modifiable(fn)
  if M._streaming then
    fn()
    return
  end
  set_chat_modifiable(true)
  local ok, err = pcall(fn)
  set_chat_modifiable(false)
  if not ok then error(err) end
end

local function append_chunk_to_chat(chunk)
  if not (M.chat_buf and api.nvim_buf_is_valid(M.chat_buf)) then return end
  local n = api.nvim_buf_line_count(M.chat_buf)
  local last = api.nvim_buf_get_lines(M.chat_buf, n - 1, n, false)[1] or ""
  if chunk:find("\n", 1, true) then
    local merged = vim.split(last .. chunk, "\n", { plain = true })
    api.nvim_buf_set_lines(M.chat_buf, n - 1, n, false, merged)
  else
    api.nvim_buf_set_lines(M.chat_buf, n - 1, n, false, { last .. chunk })
  end
end

local function flush_stream()
  local pending = M._stream_pending
  if not pending or #pending == 0 then return end
  M._stream_pending = {}

  append_chunk_to_chat(table.concat(pending))
  M.scroll_chat_to_bottom()
  -- Force a screen repaint: nvim_buf_set_lines marks the buffer dirty but
  -- won't trigger a redraw while the user is sitting in insert mode in the
  -- input window. Without this, the chat looks frozen until they move.
  pcall(vim.cmd, "redraw")
end

local function stop_stream_timer()
  if M._stream_timer then
    pcall(function()
      M._stream_timer:stop()
      if not M._stream_timer:is_closing() then
        M._stream_timer:close()
      end
    end)
    M._stream_timer = nil
  end
end

function M.begin_stream()
  ensure_chat_buf()
  M._streaming = true
  set_chat_modifiable(true)
  M._stream_pending = {}

  stop_stream_timer()
  M._stream_timer = (vim.uv or vim.loop).new_timer()
  M._stream_timer:start(STREAM_FLUSH_MS, STREAM_FLUSH_MS, vim.schedule_wrap(flush_stream))
end

function M.end_stream()
  if not M._streaming then return end
  stop_stream_timer()
  flush_stream()
  M._streaming = false
  set_chat_modifiable(false)
end

function M.set_chat_lines(lines)
  ensure_chat_buf()
  with_modifiable(function()
    api.nvim_buf_set_lines(M.chat_buf, 0, -1, false, lines)
  end)
end

function M.append_chat(lines)
  ensure_chat_buf()
  with_modifiable(function()
    local n = api.nvim_buf_line_count(M.chat_buf)
    api.nvim_buf_set_lines(M.chat_buf, n, n, false, lines)
  end)
  M.scroll_chat_to_bottom()
end

function M.stream_chat(chunk)
  if not chunk or chunk == "" then return end
  ensure_chat_buf()

  if M._streaming then
    table.insert(M._stream_pending, chunk)
    return
  end

  with_modifiable(function() append_chunk_to_chat(chunk) end)
  M.scroll_chat_to_bottom()
end

function M.input_text()
  ensure_input_buf()
  local lines = api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  return table.concat(lines, "\n")
end

function M.clear_input()
  ensure_input_buf()
  api.nvim_buf_set_lines(M.input_buf, 0, -1, false, { "" })
end

function M.set_busy(busy)
  M.busy = busy
  if M.input_win and api.nvim_win_is_valid(M.input_win) then
    pcall(api.nvim_set_option_value, "winbar",
      busy and INPUT_WINBAR_BUSY or INPUT_WINBAR_IDLE,
      { win = M.input_win })
  end
end

function M.is_busy()
  return M.busy == true
end

local function is_own_buf(buf)
  return buf == M.chat_buf or buf == M.input_buf
end

function M.get_source_buf()
  if M.source_buf and api.nvim_buf_is_valid(M.source_buf) and not is_own_buf(M.source_buf) then
    return M.source_buf
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_buf_is_valid(buf) and not is_own_buf(buf) then
      M.source_buf = buf
      return buf
    end
  end
  return nil
end

return M

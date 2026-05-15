local api = vim.api

local M = {
  chat_buf = nil,
  chat_win = nil,
  input_buf = nil,
  input_win = nil,
  source_buf = nil,
  source_win = nil,
  busy = false,
  width = 60,
  input_height = 6,
  on_submit = nil,
}

local CHAT_HEADER = {
  "# Copilot Chat",
  "",
  "Press <C-s> in insert mode (or <CR> in normal mode) inside the input box to send.",
  "",
  "---",
}

local function make_chat_buffer()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
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

local function set_chat_window_options(win)
  api.nvim_set_option_value("wrap", true, { win = win })
  api.nvim_set_option_value("linebreak", true, { win = win })
  api.nvim_set_option_value("number", false, { win = win })
  api.nvim_set_option_value("relativenumber", false, { win = win })
  api.nvim_set_option_value("signcolumn", "no", { win = win })
  api.nvim_set_option_value("foldcolumn", "0", { win = win })
  api.nvim_set_option_value("winfixwidth", true, { win = win })
end

local function set_input_window_options(win)
  api.nvim_set_option_value("wrap", true, { win = win })
  api.nvim_set_option_value("linebreak", true, { win = win })
  api.nvim_set_option_value("number", false, { win = win })
  api.nvim_set_option_value("relativenumber", false, { win = win })
  api.nvim_set_option_value("signcolumn", "no", { win = win })
  api.nvim_set_option_value("winfixheight", true, { win = win })
  api.nvim_set_option_value("winfixwidth", true, { win = win })
  pcall(api.nvim_set_option_value, "winbar", "Copilot > prompt (C-s send / CR send / q close)", { win = win })
end

local function bind_input_keys(buf)
  local function submit_lua()
    return "<cmd>lua require('copilot-chat')._submit_input()<CR>"
  end
  local function close_lua()
    return "<cmd>lua require('copilot-chat').close()<CR>"
  end
  local opts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(buf, "i", "<C-s>", "<Esc>" .. submit_lua(), opts)
  api.nvim_buf_set_keymap(buf, "n", "<CR>",  submit_lua(), opts)
  api.nvim_buf_set_keymap(buf, "n", "q",     close_lua(),  opts)
end

local function bind_chat_keys(buf)
  local opts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>lua require('copilot-chat').close()<CR>", opts)
  api.nvim_buf_set_keymap(buf, "n", "i", "<cmd>lua require('copilot-chat').focus_input()<CR>", opts)
  api.nvim_buf_set_keymap(buf, "n", "a", "<cmd>lua require('copilot-chat').focus_input()<CR>", opts)
  api.nvim_buf_set_keymap(buf, "n", "<CR>", "<cmd>lua require('copilot-chat').focus_input()<CR>", opts)
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

  local current_win = api.nvim_get_current_win()
  local current_buf = api.nvim_win_get_buf(current_win)
  if not (M.chat_buf and current_buf == M.chat_buf)
    and not (M.input_buf and current_buf == M.input_buf) then
    M.source_win = current_win
    M.source_buf = current_buf
  end

  ensure_chat_buf()
  ensure_input_buf()

  vim.cmd("botright vsplit")
  M.chat_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.chat_win, M.chat_buf)
  api.nvim_win_set_width(M.chat_win, M.width)
  set_chat_window_options(M.chat_win)

  vim.cmd("belowright split")
  M.input_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.input_win, M.input_buf)
  api.nvim_win_set_height(M.input_win, M.input_height)
  set_input_window_options(M.input_win)

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

local function with_modifiable(buf, fn)
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  local ok, err = pcall(fn)
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  if not ok then error(err) end
end

function M.set_chat_lines(lines)
  ensure_chat_buf()
  with_modifiable(M.chat_buf, function()
    api.nvim_buf_set_lines(M.chat_buf, 0, -1, false, lines)
  end)
end

function M.append_chat(lines)
  ensure_chat_buf()
  with_modifiable(M.chat_buf, function()
    local n = api.nvim_buf_line_count(M.chat_buf)
    api.nvim_buf_set_lines(M.chat_buf, n, n, false, lines)
  end)
  M.scroll_chat_to_bottom()
end

function M.stream_chat(chunk)
  if not chunk or chunk == "" then return end
  ensure_chat_buf()
  with_modifiable(M.chat_buf, function()
    local n = api.nvim_buf_line_count(M.chat_buf)
    local last = api.nvim_buf_get_lines(M.chat_buf, n - 1, n, false)[1] or ""
    if chunk:find("\n", 1, true) then
      local merged = vim.split(last .. chunk, "\n", { plain = true })
      api.nvim_buf_set_lines(M.chat_buf, n - 1, n, false, merged)
    else
      api.nvim_buf_set_lines(M.chat_buf, n - 1, n, false, { last .. chunk })
    end
  end)
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
  if M.input_buf and api.nvim_buf_is_valid(M.input_buf) then
    pcall(function()
      local label = busy
        and "Copilot is replying… (Esc to keep typing — submission disabled)"
        or "Copilot > prompt (C-s send / CR send / q close)"
      if M.input_win and api.nvim_win_is_valid(M.input_win) then
        api.nvim_set_option_value("winbar", label, { win = M.input_win })
      end
    end)
  end
end

function M.is_busy()
  return M.busy == true
end

function M.set_submit_handler(fn)
  M.on_submit = fn
end

function M.get_source_buf()
  if M.source_buf and api.nvim_buf_is_valid(M.source_buf)
    and M.source_buf ~= M.chat_buf and M.source_buf ~= M.input_buf then
    return M.source_buf
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if buf ~= M.chat_buf and buf ~= M.input_buf and api.nvim_buf_is_valid(buf) then
      M.source_buf = buf
      M.source_win = win
      return buf
    end
  end
  return nil
end

return M

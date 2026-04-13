local api = vim.api

local M = {
  chat_buf = nil,
  chat_win = nil,
  input_buf = nil,
  input_win = nil,
  source_buf = nil,
  source_win = nil,
}

--- Open the Copilot Chat UI
function M.open()
  -- If already open, focus chat window
  if M.chat_win and api.nvim_win_is_valid(M.chat_win) then
    api.nvim_set_current_win(M.chat_win)
    return
  end

  M.source_win = api.nvim_get_current_win()
  M.source_buf = api.nvim_win_get_buf(M.source_win)

  -- 1. Create the Chat Feed buffer
  M.chat_buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("filetype", "markdown", { buf = M.chat_buf })
  api.nvim_set_option_value("buftype", "nofile", { buf = M.chat_buf })
  api.nvim_set_option_value("swapfile", false, { buf = M.chat_buf })
  -- api.nvim_buf_set_name(M.chat_buf, "CopilotChat-Feed") -- Naming can sometimes conflict, keep it simple for now

  -- 2. Create the layout: Vertical split on the right
  vim.cmd("botright vsplit")
  M.chat_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(M.chat_win, M.chat_buf)
  api.nvim_win_set_width(M.chat_win, 60)

  -- 3. Polish window options
  api.nvim_set_option_value("wrap", true, { win = M.chat_win })
  api.nvim_set_option_value("number", false, { win = M.chat_win })
  api.nvim_set_option_value("relativenumber", false, { win = M.chat_win })

  -- 4. Keymaps
  local opts = { noremap = true, silent = true }
  api.nvim_buf_set_keymap(M.chat_buf, "n", "<CR>", "<cmd>lua require('copilot-chat').ask()<CR>", opts)
  api.nvim_buf_set_keymap(M.chat_buf, "n", "i", "<cmd>lua require('copilot-chat').ask()<CR>", opts)
  api.nvim_buf_set_keymap(M.chat_buf, "n", "q", "<cmd>close<CR>", opts)

  M.append_to_chat({
    "# Copilot Chat",
    "",
    "Press <Enter> to ask a question.",
    "",
    "---",
  })
end

--- Append text to the chat buffer
--- @param lines table List of strings to append
function M.append_to_chat(lines)
  if not M.chat_buf or not api.nvim_buf_is_valid(M.chat_buf) then return end
  
  -- Make modifiable temporarily to add text
  api.nvim_set_option_value("modifiable", true, { buf = M.chat_buf })
  
  local line_count = api.nvim_buf_line_count(M.chat_buf)
  
  -- Append lines to the end
  api.nvim_buf_set_lines(M.chat_buf, line_count, line_count, false, lines)
  
  -- Lock it back
  api.nvim_set_option_value("modifiable", false, { buf = M.chat_buf })
  
  -- Scroll to bottom in chat window
  if M.chat_win and api.nvim_win_is_valid(M.chat_win) then
    local new_line_count = api.nvim_buf_line_count(M.chat_buf)
    api.nvim_win_set_cursor(M.chat_win, {new_line_count, 0})
  end
end

function M.get_input_content()
  return {}
end

function M.clear_input()
  -- No-op in single-window mode
end

function M.prompt_input(on_submit)
  vim.ui.input({ prompt = "Copilot > " }, function(input)
    if input and input:gsub("%s+", "") ~= "" then
      on_submit(input)
    end
  end)
end

local diff_ns = api.nvim_create_namespace("CopilotChatDiff")

local function ensure_diff_highlights()
  -- Link to standard Neovim diff groups to match the user's colorscheme
  api.nvim_set_hl(0, "CopilotChatDiffAdd", { link = "DiffAdd", default = true })
  api.nvim_set_hl(0, "CopilotChatDiffDelete", { link = "DiffDelete", default = true })
  api.nvim_set_hl(0, "CopilotChatDiffChange", { link = "DiffChange", default = true })
end

function M.append_diff_preview(diff_text)
  if not M.chat_buf or not api.nvim_buf_is_valid(M.chat_buf) then
    return
  end

  ensure_diff_highlights()

  local diff_lines = vim.split(diff_text, "\n", { plain = true })
  local header = { "", "### Diff Preview", "```diff" }
  local footer = { "```", "" }

  api.nvim_set_option_value("modifiable", true, { buf = M.chat_buf })
  local start_line = api.nvim_buf_line_count(M.chat_buf)
  api.nvim_buf_set_lines(M.chat_buf, start_line, start_line, false, header)
  local diff_start = api.nvim_buf_line_count(M.chat_buf)
  api.nvim_buf_set_lines(M.chat_buf, diff_start, diff_start, false, diff_lines)
  local diff_end = api.nvim_buf_line_count(M.chat_buf) - 1
  api.nvim_buf_set_lines(M.chat_buf, diff_end + 1, diff_end + 1, false, footer)
  api.nvim_set_option_value("modifiable", false, { buf = M.chat_buf })

  for i, line in ipairs(diff_lines) do
    local lnum = diff_start + i - 1
    if vim.startswith(line, "@@") then
      api.nvim_buf_add_highlight(M.chat_buf, diff_ns, "CopilotChatDiffChange", lnum, 0, -1)
    elseif vim.startswith(line, "+") and not vim.startswith(line, "+++") then
      api.nvim_buf_add_highlight(M.chat_buf, diff_ns, "CopilotChatDiffAdd", lnum, 0, -1)
    elseif vim.startswith(line, "-") and not vim.startswith(line, "---") then
      api.nvim_buf_add_highlight(M.chat_buf, diff_ns, "CopilotChatDiffDelete", lnum, 0, -1)
    end
  end

  if M.chat_win and api.nvim_win_is_valid(M.chat_win) then
    local line_count = api.nvim_buf_line_count(M.chat_buf)
    api.nvim_win_set_cursor(M.chat_win, { line_count, 0 })
  end
end

function M.get_source_buf()
  if M.source_buf and api.nvim_buf_is_valid(M.source_buf) and M.source_buf ~= M.chat_buf then
    return M.source_buf
  end

  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if buf ~= M.chat_buf and api.nvim_buf_is_valid(buf) then
      return buf
    end
  end

  return nil
end

--- Stream a chunk of text to the chat buffer
--- @param chunk string The text chunk to append
function M.stream_to_chat(chunk)
  if not M.chat_buf or not api.nvim_buf_is_valid(M.chat_buf) then return end
  
  api.nvim_set_option_value("modifiable", true, { buf = M.chat_buf })
  
  local line_count = api.nvim_buf_line_count(M.chat_buf)
  local last_line = api.nvim_buf_get_lines(M.chat_buf, line_count - 1, line_count, false)[1] or ""
  
  -- Handle newlines in the chunk
  if chunk:match("\n") then
    local lines = vim.split(last_line .. chunk, "\n", { plain = true })
    api.nvim_buf_set_lines(M.chat_buf, line_count - 1, line_count, false, lines)
  else
    api.nvim_buf_set_lines(M.chat_buf, line_count - 1, line_count, false, { last_line .. chunk })
  end
  
  api.nvim_set_option_value("modifiable", false, { buf = M.chat_buf })
  
  if M.chat_win and api.nvim_win_is_valid(M.chat_win) then
    local new_line_count = api.nvim_buf_line_count(M.chat_buf)
    api.nvim_win_set_cursor(M.chat_win, {new_line_count, 0})
  end
end

return M

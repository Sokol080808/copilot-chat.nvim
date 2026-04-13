local api = vim.api

local M = {
  chat_buf = nil,
  chat_win = nil,
  input_buf = nil,
  input_win = nil,
}

--- Open the Copilot Chat UI
function M.open()
  -- If already open, focus chat window
  if M.chat_win and api.nvim_win_is_valid(M.chat_win) then
    api.nvim_set_current_win(M.chat_win)
    return
  end

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

local M = {}
local ui = require("copilot-chat.ui")
local api = require("copilot-chat.api")

-- Your default configuration
M.config = {
  system_prompt = "You are an AI programming assistant integrated into a Neovim editor.",
  auto_apply_edits = true,
  auto_apply_confirm = true,
}

M.history = {}

local function ensure_chat_history()
  if #M.history == 0 then
    table.insert(M.history, { role = "system", content = M.config.system_prompt })
  end
end

local function should_auto_apply(prompt)
  if not M.config.auto_apply_edits then
    return false
  end

  local p = prompt:lower()
  return p:find("implement", 1, true)
    or p:find("fix", 1, true)
    or p:find("refactor", 1, true)
    or p:find("update", 1, true)
    or p:find("rewrite", 1, true)
end

local function extract_code_block(text)
  if not text or text == "" then
    return nil
  end

  local _, _, body = text:find("```[%w%-_]*\n([%s%S]-)\n```")
  return body
end

local function get_source_buf()
  local source_buf = ui.get_source_buf()
  if not source_buf then
    return nil, "No source buffer found."
  end

  if vim.bo[source_buf].buftype ~= "" then
    return nil, "Target buffer is not a file buffer."
  end

  return source_buf, nil
end

local function apply_to_source_buffer(source_buf, code)
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    return false, "Source buffer is not valid."
  end

  local lines = vim.split(code, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, lines)
  return true, vim.api.nvim_buf_get_name(source_buf)
end

local function build_diff_text(old_text, new_text)
  local ok, diff = pcall(vim.diff, old_text, new_text, { result_type = "unified" })
  if ok and diff and diff ~= "" then
    return diff
  end
  return "--- current\n+++ proposed\n@@\n(diff unavailable; showing proposed content)\n" .. new_text
end

local function show_diff_preview(diff_text)
  vim.cmd("botright 15new")
  local preview_win = vim.api.nvim_get_current_win()
  local preview_buf = vim.api.nvim_get_current_buf()

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = preview_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = preview_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = preview_buf })
  vim.api.nvim_set_option_value("filetype", "diff", { buf = preview_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = preview_buf })
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, vim.split(diff_text, "\n", { plain = true }))
  vim.api.nvim_set_option_value("modifiable", false, { buf = preview_buf })

  return preview_win
end

local function with_apply_confirmation(source_buf, new_code, on_apply, on_skip)
  local old_text = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
  local diff_text = build_diff_text(old_text, new_code)

  vim.schedule(function()
    local preview_win = show_diff_preview(diff_text)
    vim.ui.select({ "Apply", "Skip" }, { prompt = "Apply Copilot changes to current file?" }, function(choice)
      if preview_win and vim.api.nvim_win_is_valid(preview_win) then
        vim.api.nvim_win_close(preview_win, true)
      end
      if choice == "Apply" then
        on_apply()
      else
        on_skip()
      end
    end)
  end)
end

local function build_messages_for_request(prompt, auto_apply)
  local messages = vim.deepcopy(M.history)
  if not auto_apply then
    return messages
  end

  local source_buf, err = get_source_buf()
  if not source_buf then
    return messages
  end

  local path = vim.api.nvim_buf_get_name(source_buf)
  local content = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
  table.insert(messages, {
    role = "system",
    content = "You are editing a file in-place. Return ONLY one fenced code block with the full updated file content. No explanations.",
  })
  table.insert(messages, {
    role = "user",
    content = "Target file: " .. path .. "\n\nCurrent file content:\n```\n" .. content .. "\n```\n\nRequested change: " .. prompt,
  })

  return messages
end

--- Setup function to initialize the plugin
--- @param opts table|nil User configuration options
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Open the chat window
function M.open()
  ui.open()
  ensure_chat_history()
end

local function submit_prompt(prompt)
  if not prompt or prompt:match("^%s*$") then
    return
  end

  ui.append_to_chat({ "", "### You", "" })
  ui.append_to_chat(vim.split(prompt, "\n", { plain = true }))
  table.insert(M.history, { role = "user", content = prompt })

  ui.append_to_chat({ "", "### Copilot", "" })

  local assistant_text = ""
  local auto_apply = should_auto_apply(prompt)
  local request_messages = build_messages_for_request(prompt, auto_apply)

  api.stream_response(request_messages, function(chunk)
    assistant_text = assistant_text .. chunk
    ui.stream_to_chat(chunk)
  end, function(final_text)
    if final_text and final_text ~= "" then
      assistant_text = final_text
    end
    if assistant_text ~= "" then
      table.insert(M.history, { role = "assistant", content = assistant_text })
    end

    if auto_apply then
      local code = extract_code_block(assistant_text)
      if code then
        local source_buf, err = get_source_buf()
        if not source_buf then
          ui.append_to_chat({ "", "⚠️ Auto-apply failed: " .. err })
        else
          local apply = function()
            local ok, info = apply_to_source_buffer(source_buf, code)
            if ok then
              ui.append_to_chat({ "", "Applied changes to: " .. info })
            else
              ui.append_to_chat({ "", "⚠️ Auto-apply failed: " .. info })
            end
            ui.append_to_chat({ "", "---", "" })
          end

          local skip = function()
            ui.append_to_chat({ "", "Skipped applying changes." })
            ui.append_to_chat({ "", "---", "" })
          end

          if M.config.auto_apply_confirm then
            with_apply_confirmation(source_buf, code, apply, skip)
            return
          end

          apply()
        end
      else
        ui.append_to_chat({ "", "⚠️ Auto-apply skipped: model did not return a fenced code block." })
      end
    end

    ui.append_to_chat({ "", "---", "" })
  end)
end

function M.ask()
  ensure_chat_history()
  ui.prompt_input(function(prompt)
    submit_prompt(prompt)
  end)
end

--- Start GitHub account login flow for GitHub Models access
function M.login()
  ui.open()
  ui.append_to_chat({ "", "### Copilot", "" })
  api.login(function(chunk)
    ui.stream_to_chat(chunk)
  end, function()
    ui.append_to_chat({ "", "---", "" })
  end)
end

--- Submit the current prompt from the input buffer
function M.submit()
  M.ask()
end

return M

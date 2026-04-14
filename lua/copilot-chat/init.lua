local M = {}
local ui = require("copilot-chat.ui")
local api = require("copilot-chat.api")

-- Your default configuration
M.config = {
  system_prompt = "You are an AI programming assistant integrated into a Neovim editor.",
  enable_edit_requests = true,
  confirm_before_apply = true,
}

M.history = {}
M.pending_confirmation = nil

local function ensure_chat_history()
  if #M.history == 0 then
    table.insert(M.history, { role = "system", content = M.config.system_prompt })
  end
end

local function should_auto_apply(prompt)
  if not M.config.enable_edit_requests then
    return false
  end

  local source_buf = ui.get_source_buf()
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    return false
  end

  if vim.bo[source_buf].buftype ~= "" then
    return false
  end

  return true
end

local function extract_code_block(text)
  if not text or text == "" then
    return nil
  end

  local _, _, body = text:find("```UPDATE\n([%s%S]-)\n```")
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

local function classify_hunk(change_old_count, change_new_count)
  if change_old_count > 0 and change_new_count > 0 then
    return "change"
  end
  if change_old_count > 0 then
    return "delete"
  end
  if change_new_count > 0 then
    return "add"
  end
  return "none"
end

local function get_buffer_window_width(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      return vim.api.nvim_win_get_width(win)
    end
  end
  return vim.o.columns
end

local function render_preview_extmarks(source_buf, ns, old_lines, new_lines)
  vim.api.nvim_buf_clear_namespace(source_buf, ns, 0, -1)

  local old_text = table.concat(old_lines, "\n")
  local new_text = table.concat(new_lines, "\n")
  local indices = vim.diff(old_text, new_text, { result_type = "indices" })
  if not (indices and #indices > 0) then
    return
  end

  local highlights = {}

  for _, hunk in ipairs(indices) do
    local start_old, count_old = hunk[1], hunk[2]
    local start_new, count_new = hunk[3], hunk[4]

    local prefix = 0
    while prefix < count_old and prefix < count_new do
      if old_lines[start_old + prefix] ~= new_lines[start_new + prefix] then
        break
      end
      prefix = prefix + 1
    end

    local suffix = 0
    while suffix < (count_old - prefix) and suffix < (count_new - prefix) do
      local old_idx = start_old + count_old - 1 - suffix
      local new_idx = start_new + count_new - 1 - suffix
      if old_lines[old_idx] ~= new_lines[new_idx] then
        break
      end
      suffix = suffix + 1
    end

    local change_old_start = start_old + prefix
    local change_new_start = start_new + prefix
    local change_old_count = count_old - prefix - suffix
    local change_new_count = count_new - prefix - suffix

    local hunk_type = classify_hunk(change_old_count, change_new_count)
    if hunk_type == "add" then
      for i = 0, change_new_count - 1 do
        table.insert(highlights, { "line", change_new_start - 1 + i, "DiffAdd" })
      end
    elseif hunk_type == "change" then
      for i = 0, change_new_count - 1 do
        table.insert(highlights, { "line", change_new_start - 1 + i, "DiffChange" })
      end
    elseif hunk_type == "delete" then
      local deleted_lines = {}
      local win_width = get_buffer_window_width(source_buf)
      for i = 0, change_old_count - 1 do
        local text = old_lines[change_old_start + i] or ""
        local pad = math.max(1, win_width - vim.fn.strdisplaywidth(text))
        table.insert(deleted_lines, {
          { text, "DiffDelete" },
          { string.rep(" ", pad), "DiffDelete" },
        })
      end

      local line_count = math.max(1, vim.api.nvim_buf_line_count(source_buf))
      local attach_line = math.min(math.max(0, change_new_start), line_count - 1)
      local above = change_new_start < line_count
      if line_count == 1 and new_lines[1] == "" then
        attach_line = 0
        above = true
      end

      table.insert(highlights, { "virt", attach_line, deleted_lines, above })
    end
  end

  for _, hl in ipairs(highlights) do
    if hl[1] == "line" then
      vim.api.nvim_buf_set_extmark(source_buf, ns, hl[2], 0, {
        line_hl_group = hl[3],
        priority = 120,
      })
    else
      vim.api.nvim_buf_set_extmark(source_buf, ns, hl[2], 0, {
        virt_lines = hl[3],
        virt_lines_above = hl[4],
        priority = 120,
      })
    end
  end
end

local function clear_preview_state(state, restore_old)
  if not state then
    return
  end

  if state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf) then
    vim.api.nvim_buf_clear_namespace(state.source_buf, state.ns, 0, -1)
    if restore_old then
      vim.api.nvim_buf_set_lines(state.source_buf, 0, -1, false, state.old_lines)
    end
  end

  M.pending_confirmation = nil
end

function M.apply_pending()
  local state = M.pending_confirmation
  if not state then
    ui.append_to_chat({ "", "No pending change preview to apply.", "", "---", "" })
    return
  end

  if not (state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf)) then
    M.pending_confirmation = nil
    ui.append_to_chat({ "", "⚠️ Pending preview target buffer is no longer valid.", "", "---", "" })
    return
  end

  vim.api.nvim_buf_clear_namespace(state.source_buf, state.ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.source_buf, 0, -1, false, state.new_lines)
  M.pending_confirmation = nil
  state.on_apply()
end

function M.skip_pending()
  local state = M.pending_confirmation
  if not state then
    ui.append_to_chat({ "", "No pending change preview to skip.", "", "---", "" })
    return
  end

  clear_preview_state(state, true)
  state.on_skip()
end

function M.refresh_pending_preview()
  local state = M.pending_confirmation
  if not state then
    return
  end

  if not (state.source_buf and vim.api.nvim_buf_is_valid(state.source_buf)) then
    M.pending_confirmation = nil
    return
  end

  render_preview_extmarks(state.source_buf, state.ns, state.old_lines, state.new_lines)
end

local function with_apply_confirmation(source_buf, new_code, on_apply, on_skip)
  vim.schedule(function()
    if M.pending_confirmation then
      clear_preview_state(M.pending_confirmation, true)
    end

    local old_text = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")

    local old_lines = vim.split(old_text, "\n", { plain = true })
    local new_lines = vim.split(new_code, "\n", { plain = true })

    local ns = vim.api.nvim_create_namespace("CopilotChatPreview")
    vim.api.nvim_buf_clear_namespace(source_buf, ns, 0, -1)

    -- Preview now shows only final file content.
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, new_lines)

    render_preview_extmarks(source_buf, ns, old_lines, new_lines)

    M.pending_confirmation = {
      source_buf = source_buf,
      old_lines = old_lines,
      new_lines = new_lines,
      ns = ns,
      on_apply = on_apply,
      on_skip = on_skip,
    }

    ui.append_to_chat({
      "",
      "Preview ready (non-blocking).",
      "Use :CopilotChatApply to accept or :CopilotChatSkip to discard.",
    })
    vim.cmd("redraw")
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

  table.remove(messages)

  local path = vim.api.nvim_buf_get_name(source_buf)
  local content = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
  table.insert(messages, {
    role = "system",
    content = "You are an AI programming assistant in Neovim.\nIf the user asks a general question, answer normally.\nIf the user asks you to modify/write/refactor the current file, output the COMPLETE updated file in a single fenced code block starting EXACTLY with ```UPDATE\n...content...\n```. Do not provide any other text.",
  })
  table.insert(messages, {
    role = "user",
    content = "Target file: " .. path .. "\n\nCurrent file content:\n```\n" .. content .. "\n```\n\nRequested change/question: " .. prompt,
  })

  return messages
end

--- Setup function to initialize the plugin
--- @param opts table|nil User configuration options
function M.setup(opts)
  opts = opts or {}

  -- Backward-compatible aliases for legacy option names.
  if opts.auto_apply_edits ~= nil and opts.enable_edit_requests == nil then
    opts.enable_edit_requests = opts.auto_apply_edits
  end
  if opts.auto_apply_confirm ~= nil and opts.confirm_before_apply == nil then
    opts.confirm_before_apply = opts.auto_apply_confirm
  end

  opts.auto_apply_edits = nil
  opts.auto_apply_confirm = nil

  M.config = vim.tbl_deep_extend("force", M.config, opts)

  local group = vim.api.nvim_create_augroup("CopilotChatPreviewResize", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      M.refresh_pending_preview()
    end,
  })
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
          local apply = function(already_applied)
            if already_applied then
              ui.append_to_chat({ "", "Applied changes to: " .. vim.api.nvim_buf_get_name(source_buf) })
            else
              local ok, info = apply_to_source_buffer(source_buf, code)
              if ok then
                ui.append_to_chat({ "", "Applied changes to: " .. info })
              else
                ui.append_to_chat({ "", "⚠️ Auto-apply failed: " .. info })
              end
            end
            ui.append_to_chat({ "", "---", "" })
          end

          local skip = function()
            ui.append_to_chat({ "", "Skipped applying changes." })
            ui.append_to_chat({ "", "---", "" })
          end

          if M.config.confirm_before_apply then
            with_apply_confirmation(source_buf, code, function()
              apply(true)
            end, skip)
            return
          end

          apply(false)
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

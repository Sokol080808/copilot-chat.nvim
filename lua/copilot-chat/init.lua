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

  local source_buf = ui.get_source_buf()
  local context = {
    has_open_file = source_buf and vim.api.nvim_buf_is_valid(source_buf) and vim.bo[source_buf].buftype == "" or false,
    file_path = source_buf and vim.api.nvim_buf_get_name(source_buf) or "",
    filetype = source_buf and vim.bo[source_buf].filetype or "",
  }

  return api.detect_edit_intent(prompt, context)
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

local function with_apply_confirmation(source_buf, new_code, on_apply, on_skip)
  vim.schedule(function()
    local old_text = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
    local indices = vim.diff(old_text, new_code, { result_type = "indices" })

    local old_lines = vim.split(old_text, "\n", { plain = true })
    local new_lines = vim.split(new_code, "\n", { plain = true })

    local ns = vim.api.nvim_create_namespace("CopilotChatPreview")
    vim.api.nvim_buf_clear_namespace(source_buf, ns, 0, -1)

    if indices and #indices > 0 then
      local combined_lines = {}
      local highlights = {}
      local last_new = 1

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

        local insert_up_to = count_new == 0 and (start_new + prefix) or (start_new + prefix - 1)

        while last_new <= insert_up_to do
          table.insert(combined_lines, new_lines[last_new])
          last_new = last_new + 1
        end

        for i = 0, change_old_count - 1 do
          table.insert(combined_lines, old_lines[change_old_start + i])
          table.insert(highlights, { #combined_lines - 1, "DiffDelete" })
        end

        local hunk_type = classify_hunk(change_old_count, change_new_count)
        local new_hl = hunk_type == "change" and "DiffChange" or "DiffAdd"

        for i = 0, change_new_count - 1 do
          table.insert(combined_lines, new_lines[change_new_start + i])
          table.insert(highlights, { #combined_lines - 1, new_hl })
        end

        last_new = math.max(last_new, change_new_start + change_new_count)
      end

      while last_new <= #new_lines do
        table.insert(combined_lines, new_lines[last_new])
        last_new = last_new + 1
      end

      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, combined_lines)

      for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_set_extmark(source_buf, ns, hl[1], 0, {
          line_hl_group = hl[2],
          priority = 120,
        })
      end
    else
      -- No diff, just apply the new code unconditionally
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, new_lines)
    end

    vim.cmd("redraw") -- Force UI update so the user can see the diff before the prompt blocks

    vim.ui.select({ "Apply", "Skip" }, { prompt = "Keep these Copilot changes?" }, function(choice)
      vim.api.nvim_buf_clear_namespace(source_buf, ns, 0, -1)
      if choice == "Apply" then
        on_apply()
      else
        vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, old_lines)
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

          if M.config.auto_apply_confirm then
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

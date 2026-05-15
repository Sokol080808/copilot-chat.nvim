local api = vim.api
local M = {}

M.pending = nil

local function classify(old_count, new_count)
  if old_count > 0 and new_count > 0 then return "change" end
  if old_count > 0 then return "delete" end
  if new_count > 0 then return "add" end
  return "none"
end

local function buffer_window_width(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_is_valid(win) then
      return api.nvim_win_get_width(win)
    end
  end
  return vim.o.columns
end

local function render_extmarks(buf, ns, old_lines, new_lines)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local indices = vim.diff(table.concat(old_lines, "\n"), table.concat(new_lines, "\n"), { result_type = "indices" })
  if not (indices and #indices > 0) then
    return
  end

  local marks = {}

  for _, hunk in ipairs(indices) do
    local start_old, count_old = hunk[1], hunk[2]
    local start_new, count_new = hunk[3], hunk[4]

    local prefix = 0
    while prefix < count_old and prefix < count_new
      and old_lines[start_old + prefix] == new_lines[start_new + prefix] do
      prefix = prefix + 1
    end

    local suffix = 0
    while suffix < (count_old - prefix) and suffix < (count_new - prefix)
      and old_lines[start_old + count_old - 1 - suffix] == new_lines[start_new + count_new - 1 - suffix] do
      suffix = suffix + 1
    end

    local change_old_start = start_old + prefix
    local change_new_start = start_new + prefix
    local change_old_count = count_old - prefix - suffix
    local change_new_count = count_new - prefix - suffix

    local kind = classify(change_old_count, change_new_count)
    if kind == "add" then
      for i = 0, change_new_count - 1 do
        table.insert(marks, { "line", change_new_start - 1 + i, "DiffAdd" })
      end
    elseif kind == "change" then
      for i = 0, change_new_count - 1 do
        table.insert(marks, { "line", change_new_start - 1 + i, "DiffChange" })
      end
    elseif kind == "delete" then
      local virt = {}
      local width = buffer_window_width(buf)
      for i = 0, change_old_count - 1 do
        local text = old_lines[change_old_start + i] or ""
        local pad = math.max(1, width - vim.fn.strdisplaywidth(text))
        table.insert(virt, {
          { text, "DiffDelete" },
          { string.rep(" ", pad), "DiffDelete" },
        })
      end

      local line_count = math.max(1, api.nvim_buf_line_count(buf))
      local attach = math.min(math.max(0, change_new_start), line_count - 1)
      local above = change_new_start < line_count
      if line_count == 1 and new_lines[1] == "" then
        attach = 0
        above = true
      end

      table.insert(marks, { "virt", attach, virt, above })
    end
  end

  for _, m in ipairs(marks) do
    if m[1] == "line" then
      api.nvim_buf_set_extmark(buf, ns, m[2], 0, { line_hl_group = m[3], priority = 120 })
    else
      api.nvim_buf_set_extmark(buf, ns, m[2], 0, {
        virt_lines = m[3],
        virt_lines_above = m[4],
        priority = 120,
      })
    end
  end
end

local function clear(state, restore_old)
  if not state then return end
  if state.source_buf and api.nvim_buf_is_valid(state.source_buf) then
    api.nvim_buf_clear_namespace(state.source_buf, state.ns, 0, -1)
    if restore_old then
      api.nvim_buf_set_lines(state.source_buf, 0, -1, false, state.old_lines)
    end
  end
  M.pending = nil
end

--- Show an inline preview of new_code in source_buf and stash it for apply/skip.
function M.preview(source_buf, new_code, on_apply, on_skip)
  vim.schedule(function()
    if M.pending then
      clear(M.pending, true)
    end

    local old_lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
    local new_lines = vim.split(new_code, "\n", { plain = true })

    local ns = api.nvim_create_namespace("CopilotChatPreview")
    api.nvim_buf_clear_namespace(source_buf, ns, 0, -1)
    api.nvim_buf_set_lines(source_buf, 0, -1, false, new_lines)
    render_extmarks(source_buf, ns, old_lines, new_lines)

    M.pending = {
      source_buf = source_buf,
      old_lines = old_lines,
      new_lines = new_lines,
      ns = ns,
      on_apply = on_apply or function() end,
      on_skip = on_skip or function() end,
    }
    vim.cmd("redraw")
  end)
end

function M.apply()
  local state = M.pending
  if not state then return false, "no pending preview" end
  if not (state.source_buf and api.nvim_buf_is_valid(state.source_buf)) then
    M.pending = nil
    return false, "preview target buffer is gone"
  end

  api.nvim_buf_clear_namespace(state.source_buf, state.ns, 0, -1)
  api.nvim_buf_set_lines(state.source_buf, 0, -1, false, state.new_lines)
  M.pending = nil
  state.on_apply()
  return true
end

function M.skip()
  local state = M.pending
  if not state then return false, "no pending preview" end
  clear(state, true)
  state.on_skip()
  return true
end

function M.refresh()
  local state = M.pending
  if not state then return end
  if not (state.source_buf and api.nvim_buf_is_valid(state.source_buf)) then
    M.pending = nil
    return
  end
  render_extmarks(state.source_buf, state.ns, state.old_lines, state.new_lines)
end

return M

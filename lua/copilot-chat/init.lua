local api = require("copilot-chat.api")
local ui = require("copilot-chat.ui")
local diff = require("copilot-chat.diff")
local prompt_mod = require("copilot-chat.prompt")

local M = {}

M.config = {
  system_prompt = nil,
  edit_fence_tag = "UPDATE",
  default_keymaps = false,
  -- Send a one-shot guide file (default: the bundled GUIDE.md) on the first
  -- user message of a session. The CLI keeps it in conversation memory via
  -- --resume, so subsequent turns don't re-pay the token cost. Set false to
  -- disable. The runtime [Editor context] block still ships every turn.
  use_guide = true,
  -- Override path to a custom guide file. nil → bundled GUIDE.md.
  guide_path = nil,
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

local function read_guide()
  local path = M.config.guide_path
  if not path or path == "" then
    local found = vim.api.nvim_get_runtime_file("lua/copilot-chat/GUIDE.md", false)
    if #found == 0 then return nil end
    path = found[1]
  end
  if vim.fn.filereadable(path) == 0 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return nil end
  return table.concat(lines, "\n")
end

local function build_user_message(prompt)
  if not M._first_turn then return prompt end

  local prelude = {}
  if M.config.use_guide then
    local guide = read_guide()
    if guide and guide ~= "" then table.insert(prelude, guide) end
  end
  if M.config.system_prompt and M.config.system_prompt ~= "" then
    table.insert(prelude, M.config.system_prompt)
  end

  if #prelude == 0 then return prompt end
  return table.concat(prelude, "\n\n") .. "\n\n" .. prompt
end

local function abs_path(p)
  return vim.fn.fnamemodify(p, ":p")
end

local function short_path(path)
  if not path or path == "" then return "<unnamed>" end
  return vim.fn.fnamemodify(path, ":~:.")
end

--- Compute --add-dir entries for files outside the working directory.
local function extra_dirs_for(open_files, cwd)
  local cwd_abs = abs_path(cwd or vim.fn.getcwd())
  if cwd_abs:sub(-1) ~= "/" then cwd_abs = cwd_abs .. "/" end
  local seen, dirs = {}, {}
  for _, f in ipairs(open_files or {}) do
    local file_abs = abs_path(f)
    if not vim.startswith(file_abs, cwd_abs) then
      local parent = vim.fn.fnamemodify(file_abs, ":h")
      if not seen[parent] then
        seen[parent] = true
        table.insert(dirs, parent)
      end
    end
  end
  return dirs
end

local function send(prompt, on_text, on_done, send_opts)
  ensure_session()
  send_opts = send_opts or {}

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
  }, {
    cwd = send_opts.cwd,
    add_dirs = send_opts.add_dirs,
    deny_writes = send_opts.deny_writes,
  })
end

local function context_preamble(ctx, range, hint_workspace)
  local parts = {}
  table.insert(parts, "[Editor context]")
  table.insert(parts, "cwd: " .. ctx.cwd)
  if hint_workspace then
    table.insert(parts, "user invoked @workspace: prefer to actively search the workspace (bash/grep/view) before answering instead of guessing.")
  end

  if ctx.active then
    local active = "active file: " .. short_path(ctx.active.path)
    if ctx.active.row then
      active = active .. " (cursor: line " .. ctx.active.row .. ")"
    end
    table.insert(parts, active)
  else
    table.insert(parts, "active file: <none>")
  end

  local others = {}
  for _, p in ipairs(ctx.open or {}) do
    if not (ctx.active and ctx.active.path == p) then
      table.insert(others, "  - " .. short_path(p))
    end
  end
  if #others > 0 then
    table.insert(parts, "other open files:")
    vim.list_extend(parts, others)
  end

  if range and range.lines and #range.lines > 0 and ctx.active then
    table.insert(parts, "user has selected lines "
      .. range.start_line .. "-" .. range.end_line
      .. " of " .. short_path(ctx.active.path) .. ":")
    table.insert(parts, "```")
    vim.list_extend(parts, range.lines)
    table.insert(parts, "```")
  end

  table.insert(parts, "[End of editor context]")
  return table.concat(parts, "\n")
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

local function show_slash_help()
  local lines = { "", "### Copilot", "", "Available slash commands:" }
  local names = vim.tbl_keys(prompt_mod.slash_commands)
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(lines, "- `/" .. name .. "` — " .. prompt_mod.slash_commands[name].description)
  end
  table.insert(lines, "")
  table.insert(lines, "References: type `#file:path/to/foo.lua` to inline a file. Add `@workspace` to nudge Copilot to search the project.")
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  ui.append_chat(lines)
end

--- Build the actual prompt sent to Copilot from the user's raw input.
--- Returns:
---   sent_text     - the text sent to Copilot (slash + #file expanded, @workspace stripped)
---   has_workspace - whether @workspace was present
---   refs          - file refs metadata (for chat hint lines)
---   meta_slash    - "help" or "clear" if the user invoked one of those (caller handles)
local function compose_prompt(text, ctx)
  local expanded, slash_name = prompt_mod.expand_slash(text, ctx)
  if slash_name == "help" or slash_name == "clear" then
    return nil, false, {}, slash_name
  end
  local resolved, refs = prompt_mod.expand_file_refs(expanded, ctx.cwd)
  local stripped, has_workspace = prompt_mod.expand_workspace(resolved)
  return stripped, has_workspace, refs, nil
end

local function submit_chat(prompt, range)
  if not prompt or vim.trim(prompt) == "" then return end
  if reject_if_busy() then return end

  local ctx = ui.get_editor_context()

  if range and range.start_line and range.end_line and ctx.active then
    local source_buf, _ = source_file_buf()
    if source_buf then
      range.lines = vim.api.nvim_buf_get_lines(source_buf, range.start_line - 1, range.end_line, false)
    end
  end

  local body, has_workspace, refs, meta_slash = compose_prompt(prompt, ctx)

  -- Echo the user's literal input first.
  append_user_message("You", prompt)
  ui.clear_input()

  if meta_slash == "help" then
    show_slash_help()
    return
  end
  if meta_slash == "clear" then
    M.new_session()
    return
  end

  if refs and #refs > 0 then
    local hints = {}
    for _, r in ipairs(refs) do
      if r.ok then
        table.insert(hints, "  - `" .. r.path .. "` (" .. r.line_count .. " lines)")
      else
        table.insert(hints, "  - `" .. r.path .. "` — " .. r.error)
      end
    end
    ui.append_chat({ "", "> 📎 Inlined files:" })
    ui.append_chat(hints)
  end

  open_assistant_block()

  local preamble = context_preamble(ctx, range, has_workspace)
  local final_prompt = preamble .. "\n\n" .. body

  send(final_prompt, ui.stream_chat, function()
    close_message_block()
  end, {
    cwd = ctx.cwd,
    add_dirs = extra_dirs_for(ctx.open, ctx.cwd),
  })
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
    "You are editing a file inside Neovim via the plugin's diff-preview flow.",
    "DO NOT use write/edit/file-modification tools — they are disabled for this request. The user wants to review the change before it lands on disk.",
    "Return the COMPLETE updated file content in a single fenced code block opening with ```" .. tag .. " and closing with ```. Nothing else. No prose. No explanation. The plugin will extract that block, overlay an inline diff in the user's buffer, and they will accept or reject it with :CopilotChatApply / :CopilotChatSkip.",
    "Preserve the existing indentation style and only change what the request asks for — leave unrelated lines exactly as they are.",
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

  local ctx = ui.get_editor_context()
  local others = {}
  for _, p in ipairs(ctx.open or {}) do
    if p ~= path then table.insert(others, "  - " .. short_path(p)) end
  end
  if #others > 0 then
    instructions = instructions
      .. "\n\nOther files currently open in the user's editor (use the view tool to read any of them if needed):\n"
      .. table.concat(others, "\n")
  end

  instructions = instructions .. "\n\nRequested change:\n" .. prompt

  append_user_message("You (edit)", prompt)
  ui.append_chat({ "", "> ✏️ Generating edit for `" .. label .. "`…" })
  ui.clear_input()

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
  end, {
    cwd = ctx.cwd,
    add_dirs = extra_dirs_for(ctx.open, ctx.cwd),
    deny_writes = true,
  })
end

local function install_default_keymaps()
  local set = vim.keymap.set
  set({ "n" }, "<leader>cc", "<cmd>CopilotChat<CR>",          { silent = true, desc = "Toggle Copilot chat" })
  set({ "n" }, "<leader>ca", "<cmd>CopilotChatAsk<CR>",       { silent = true, desc = "Copilot chat: ask" })
  set({ "v" }, "<leader>ca", ":CopilotChatAsk ",              { silent = false, desc = "Copilot chat: ask about selection" })
  set({ "n" }, "<leader>ci", ":CopilotChatEdit ",             { silent = false, desc = "Copilot edit current file" })
  set({ "v" }, "<leader>ci", ":CopilotChatEdit ",             { silent = false, desc = "Copilot edit selection" })
  set({ "n" }, "<leader>cf", "<cmd>CopilotChatFixDiagnostic<CR>", { silent = true, desc = "Copilot fix diagnostic at cursor" })
  set({ "n" }, "<leader>cn", "<cmd>CopilotChatNew<CR>",       { silent = true, desc = "Copilot new chat session" })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  local group = vim.api.nvim_create_augroup("CopilotChatPreviewResize", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function() diff.refresh() end,
  })

  if M.config.default_keymaps then
    install_default_keymaps()
  end
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

function M.send_prompt(prompt, range)
  ui.open()
  submit_chat(prompt, range)
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

--- Run a slash command directly (used by :CopilotChatExplain, /Tests, etc.).
function M.slash(name, arg, range)
  if not prompt_mod.slash_commands[name] then
    vim.notify("Unknown slash command: /" .. name, vim.log.levels.ERROR)
    return
  end
  local literal = "/" .. name
  if arg and arg ~= "" then literal = literal .. " " .. arg end
  M.send_prompt(literal, range)
end

--- Submit the diagnostic(s) at the cursor in the source window as an edit
--- request. If there's nothing on this line, falls back to all diagnostics
--- in the buffer (still narrows by severity).
function M.fix_diagnostic()
  local source_buf, err = source_file_buf()
  if not source_buf then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local source_win = ui.source_win
  if not (source_win and vim.api.nvim_win_is_valid(source_win)
      and vim.api.nvim_win_get_buf(source_win) == source_buf) then
    source_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == source_buf then
        source_win = w
        break
      end
    end
  end

  local lnum = nil
  if source_win then
    lnum = vim.api.nvim_win_get_cursor(source_win)[1] - 1
  end

  local diags = lnum and vim.diagnostic.get(source_buf, { lnum = lnum }) or {}
  local scope = "line " .. (lnum and (lnum + 1) or "?")
  if #diags == 0 then
    diags = vim.diagnostic.get(source_buf)
    scope = "buffer"
  end
  if #diags == 0 then
    vim.notify("No diagnostics in this buffer.", vim.log.levels.INFO)
    return
  end

  local descs = {}
  for _, d in ipairs(diags) do
    local severity = vim.diagnostic.severity[d.severity] or "?"
    table.insert(descs, "- " .. severity .. " line " .. (d.lnum + 1)
      .. " col " .. ((d.col or 0) + 1)
      .. (d.source and (" [" .. d.source .. "]") or "")
      .. ": " .. (d.message or ""))
  end

  local p = "Fix the following diagnostics in this file (" .. scope .. "):\n"
    .. table.concat(descs, "\n")
    .. "\n\nMake the smallest change that resolves them. Don't drift into unrelated edits."
  M.edit(p, nil)
end

M.slash_commands = prompt_mod.slash_commands

--- Smart <Tab> in the input buffer: trigger user completion when after `/` or
--- `#file:`; otherwise behave like a normal Tab.
function M._tab()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local termcodes
  if before:match("#file:%S*$") or before:match("/[%w_%-]*$") then
    termcodes = vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true)
  else
    termcodes = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
  end
  vim.api.nvim_feedkeys(termcodes, "n", false)
end

--- omnifunc / completefunc body for the input buffer.
function M._complete(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)

  if findstart == 1 then
    local s = before:find("#file:%S*$")
    if s then
      return s + 5  -- after "#file:" prefix
    end
    s = before:find("/[%w_%-]*$")
    if s then
      return s - 1  -- include the leading slash
    end
    return -1
  end

  if before:match("#file:%S*$") then
    local matches = {}
    local handle = io.popen("git ls-files 2>/dev/null")
    if handle then
      for f in handle:lines() do
        if base == "" or f:find(base, 1, true) then
          table.insert(matches, f)
          if #matches >= 50 then break end
        end
      end
      handle:close()
    end
    return matches
  end

  if base:sub(1, 1) == "/" then
    local matches = {}
    local names = vim.tbl_keys(prompt_mod.slash_commands)
    table.sort(names)
    for _, name in ipairs(names) do
      local word = "/" .. name
      if word:find(base, 1, true) == 1 then
        table.insert(matches, { word = word, menu = prompt_mod.slash_commands[name].description })
      end
    end
    return matches
  end

  return {}
end

return M

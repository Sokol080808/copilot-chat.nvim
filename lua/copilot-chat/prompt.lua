local M = {}

local function default_target(ctx)
  if ctx and ctx.active and ctx.active.path then
    return "the active file (" .. vim.fn.fnamemodify(ctx.active.path, ":~:.") .. ")"
  end
  return "the active file"
end

M.slash_commands = {
  explain = {
    description = "Explain how the code works",
    template = function(arg, ctx)
      local target = (arg ~= "" and arg) or default_target(ctx)
      return "Explain how " .. target .. " works. Walk through the key functions, the data flow, and any non-obvious behavior. Be concise."
    end,
  },
  tests = {
    description = "Generate unit tests",
    template = function(arg, ctx)
      local target = (arg ~= "" and arg) or default_target(ctx)
      return "Generate unit tests for " .. target .. ". Cover the main happy paths and important edge cases. Use the project's existing test framework — read other test files to match style."
    end,
  },
  fix = {
    description = "Propose a fix for a problem",
    template = function(arg, ctx)
      if arg ~= "" then
        return "Fix the following: " .. arg
      end
      return "Look at " .. default_target(ctx) .. " near the cursor and propose a fix for the most prominent problem there (compile/lint error, bug, or missing case)."
    end,
  },
  doc = {
    description = "Add documentation",
    template = function(arg, ctx)
      local target = (arg ~= "" and arg) or default_target(ctx)
      return "Add concise documentation to " .. target .. ". Document non-obvious behavior, parameters, return values, and side effects. Skip what's already obvious from the names."
    end,
  },
  optimize = {
    description = "Suggest performance improvements",
    template = function(arg, ctx)
      local target = (arg ~= "" and arg) or default_target(ctx)
      return "Review " .. target .. " for performance issues. Focus on hot paths, redundant work, and obvious inefficiencies. Suggest concrete changes."
    end,
  },
  review = {
    description = "Code review",
    template = function(arg, ctx)
      local target = (arg ~= "" and arg) or default_target(ctx)
      return "Do a focused code review of " .. target .. ". Flag bugs, hacky patterns, and quality issues. Skip nitpicks."
    end,
  },
  help = {
    description = "List the available slash commands",
    template = function() return nil end,
  },
  clear = {
    description = "Start a fresh Copilot session (same as :CopilotChatNew)",
    template = function() return nil end,
  },
}

function M.parse_slash(text)
  if type(text) ~= "string" or text:sub(1, 1) ~= "/" then
    return nil, nil
  end
  local cmd, arg = text:match("^/(%S+)%s*(.*)$")
  if not cmd then return nil, nil end
  return cmd, arg or ""
end

--- Expand a `/cmd args` prefix into a full prompt using the registry.
--- Returns:
---   expanded text, slash entry name (or nil), arg
function M.expand_slash(text, ctx)
  local cmd, arg = M.parse_slash(text)
  if not cmd then return text, nil, nil end
  local entry = M.slash_commands[cmd]
  if not entry then return text, nil, nil end
  local body = entry.template(arg, ctx)
  if body == nil then
    return text, cmd, arg
  end
  return body, cmd, arg
end

--- Replace `#file:path` tokens with the file's content (fenced).
--- Returns:
---   resolved text, list of { path, abs, ok=true|false, error? }
function M.expand_file_refs(text, base_dir)
  if type(text) ~= "string" then return text, {} end
  local refs = {}
  local cwd = base_dir or vim.fn.getcwd()
  local resolved = text:gsub("#file:(%S+)", function(path)
    local abs = path
    if path:sub(1, 1) ~= "/" then
      abs = vim.fn.fnamemodify(cwd .. "/" .. path, ":p")
    else
      abs = vim.fn.fnamemodify(path, ":p")
    end
    if vim.fn.filereadable(abs) == 0 then
      table.insert(refs, { path = path, abs = abs, ok = false, error = "not readable" })
      return "[#file:" .. path .. " — not readable]"
    end
    local ok, lines = pcall(vim.fn.readfile, abs)
    if not ok then
      table.insert(refs, { path = path, abs = abs, ok = false, error = "read error" })
      return "[#file:" .. path .. " — read error]"
    end
    table.insert(refs, { path = path, abs = abs, ok = true, line_count = #lines })
    return "\n[" .. path .. "]\n```\n" .. table.concat(lines, "\n") .. "\n```\n"
  end)
  return resolved, refs
end

local function looks_like_path(s)
  if not s or s == "" then return false end
  if s:find("/", 1, true) then return true end
  if s:sub(1, 1) == "." then return true end          -- .gitignore, .env
  if s:match("^[%w_%-]+%.[%w%-]+$") then return true end -- foo.lua, README.md
  return false
end

local function parse_info(info)
  info = vim.trim(info or "")
  if info == "" then return nil, nil end

  -- "lang filename" or "lang:filename"
  local first, rest = info:match("^([^%s:]+)[%s:]+(.+)$")
  if first and rest then
    rest = vim.trim(rest)
    if looks_like_path(rest) then
      return first, rest
    end
  end

  if looks_like_path(info) then
    return nil, info
  end

  return info, nil  -- bare language tag
end

--- Parse fenced code blocks out of an assistant reply.
--- Returns a list of { info, lang, filename, content }.
function M.extract_code_blocks(text)
  if type(text) ~= "string" or text == "" then return {} end
  local blocks = {}
  for info, content in text:gmatch("```([^\n]*)\n(.-)\n```") do
    local lang, filename = parse_info(info)
    table.insert(blocks, {
      info = info,
      lang = lang,
      filename = filename,
      content = content,
    })
  end
  return blocks
end

--- Detect (and strip) an `@workspace` token. The CLI already has filesystem
--- access; this just nudges the model in the system preamble.
function M.expand_workspace(text)
  if type(text) ~= "string" then return text, false end
  if not text:find("@workspace", 1, true) then
    return text, false
  end
  local stripped = (text:gsub("@workspace%s*", ""))
  return stripped, true
end

return M

if vim.g.loaded_copilot_chat then
  return
end
vim.g.loaded_copilot_chat = true

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd("CopilotChat", function() require("copilot-chat").toggle() end)
cmd("CopilotChatOpen", function() require("copilot-chat").open() end)
cmd("CopilotChatClose", function() require("copilot-chat").close() end)
cmd("CopilotChatAsk", function(opts)
  local cc = require("copilot-chat")
  local range = nil
  if opts.range and opts.range > 0 then
    range = { start_line = opts.line1, end_line = opts.line2 }
  end
  if opts.args and opts.args ~= "" then
    cc.send_prompt(opts.args, range)
  else
    cc.ask()
  end
end, { nargs = "?", range = true })

cmd("CopilotChatNew",    function() require("copilot-chat").new_session() end)
cmd("CopilotChatApply",  function() require("copilot-chat").apply_pending() end)
cmd("CopilotChatSkip",   function() require("copilot-chat").skip_pending() end)
cmd("CopilotChatCancel", function() require("copilot-chat").cancel() end)
cmd("CopilotChatLogin",  function() require("copilot-chat").login() end)

local function slash_cmd(cmd_name, slash_name)
  cmd(cmd_name, function(opts)
    local range = nil
    if opts.range and opts.range > 0 then
      range = { start_line = opts.line1, end_line = opts.line2 }
    end
    require("copilot-chat").slash(slash_name, opts.args, range)
  end, { nargs = "?", range = true })
end

slash_cmd("CopilotChatExplain",  "explain")
slash_cmd("CopilotChatTests",    "tests")
slash_cmd("CopilotChatFix",      "fix")
slash_cmd("CopilotChatDoc",      "doc")
slash_cmd("CopilotChatOptimize", "optimize")
slash_cmd("CopilotChatReview",   "review")

cmd("CopilotChatFixDiagnostic", function() require("copilot-chat").fix_diagnostic() end)

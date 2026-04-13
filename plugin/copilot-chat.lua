if vim.g.loaded_copilot_chat then
  return
end
vim.g.loaded_copilot_chat = true

-- Define commands or auto-commands here
vim.api.nvim_create_user_command("CopilotChat", function()
  require("copilot-chat").open()
end, {})

vim.api.nvim_create_user_command("CopilotChatLogin", function()
  require("copilot-chat").login()
end, {})

vim.api.nvim_create_user_command("CopilotChatAsk", function()
  require("copilot-chat").ask()
end, {})

vim.api.nvim_create_user_command("CopilotChatUsage", function()
  require("copilot-chat").usage()
end, {})

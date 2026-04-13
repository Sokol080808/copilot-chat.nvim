if vim.g.loaded_copilot_chat then
  return
end
vim.g.loaded_copilot_chat = true

-- Define commands or auto-commands here
vim.api.nvim_create_user_command("CopilotChat", function()
  require("copilot-chat").open()
end, {})

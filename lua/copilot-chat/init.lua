local M = {}
local ui = require("copilot-chat.ui")
local api = require("copilot-chat.api")

-- Your default configuration
M.config = {
  -- Add default options here
}

--- Setup function to initialize the plugin
--- @param opts table|nil User configuration options
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Open the chat window
function M.open()
  ui.open()
end

--- Submit the current prompt from the input buffer
function M.submit()
  local lines = ui.get_input_content()
  
  -- Filter empty lines (optional, just to keep it clean)
  local prompt = table.concat(lines, "\n")
  if prompt:match("^%s*$") then
    return -- Empty prompt
  end

  -- 1. Display User Message
  ui.append_to_chat({ "", "### You", "" })
  ui.append_to_chat(lines)
  
  -- 2. Clear input
  ui.clear_input()
Streaming
  ui.append_to_chat({ "", "### Copilot", "" })
  
  api.stream_response(prompt, function(chunk)
    ui.stream_to_chat(chunk)
  end, function()
    ui.append_to_chat({ "", "---", "" }) -- Add a separator when done
  end
  ui.append_to_chat({ "", "### Copilot", "", "I am a Neovim plugin trying to be an AI! You said:", "```text", prompt, "```" })
end

return M

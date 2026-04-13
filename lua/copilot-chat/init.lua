local M = {}
local ui = require("copilot-chat.ui")
local api = require("copilot-chat.api")

-- Your default configuration
M.config = {
  system_prompt = "You are an AI programming assistant integrated into a Neovim editor.",
}

M.history = {}

local function ensure_chat_history()
  if #M.history == 0 then
    table.insert(M.history, { role = "system", content = M.config.system_prompt })
  end
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
  ensure_chat_history()

  local lines = ui.get_input_content()
  
  -- Filter empty lines (optional, just to keep it clean)
  local prompt = table.concat(lines, "\n")
  if prompt:match("^%s*$") then
    return -- Empty prompt
  end

  -- 1. Display User Message
  ui.append_to_chat({ "", "### You", "" })
  ui.append_to_chat(lines)
  table.insert(M.history, { role = "user", content = prompt })
  
  -- 2. Clear input
  ui.clear_input()

  -- 3. Connect to API and Stream Response
  ui.append_to_chat({ "", "### Copilot", "" })

  local assistant_text = ""
  api.stream_response(M.history, function(chunk)
    ui.stream_to_chat(chunk)
  end, function(final_text)
    if final_text and final_text ~= "" then
      assistant_text = final_text
    end
    if assistant_text ~= "" then
      table.insert(M.history, { role = "assistant", content = assistant_text })
    end
    ui.append_to_chat({ "", "---", "" }) -- Add a separator when done
  end)
end

return M

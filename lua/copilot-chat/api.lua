local M = {}

--- Fetch response using a dummy streaming simulation
--- In a real plugin, you would use `vim.fn.jobstart` with `curl` here.
--- @param prompt string The user prompt
--- @param on_chunk function Callback for each text chunk
--- @param on_done function Callback when finished
function M.stream_response(prompt, on_chunk, on_done)
  local response_text = "Here is a simulated response to: '" .. prompt .. "'\n\n```lua\nprint('Hello from Neovim!')\n```\n\nI can be configured to call real APIs like OpenAI or GitHub Copilot using `curl` and `vim.fn.jobstart`."
  
  local words = {}
  for word in response_text:gmatch("%S+%s*") do
    table.insert(words, word)
  end

  local i = 1
  local function send_next()
    if i <= #words then
      on_chunk(words[i])
      i = i + 1
      vim.defer_fn(send_next, 50) -- 50ms delay between words to simulate network stream
    else
      if on_done then on_done() end
    end
  end

  send_next()
end

return M

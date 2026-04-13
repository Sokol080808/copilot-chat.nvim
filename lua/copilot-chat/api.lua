local M = {}

-- Global variables to cache the session token
local copilot_token = nil
local copilot_token_expires = 0
local copilot_client_id = "01ab8ac9400c4e429b23" -- Standard GitHub Copilot Client ID

--- Find the GitHub OAuth token from the official Copilot environment
local function get_github_oauth_token()
  local config_paths = {
    vim.fn.expand("~/.config/github-copilot/hosts.json"),
    vim.fn.expand("~/.config/github-copilot/apps.json"),
    vim.fn.expand("~/Library/Application Support/github-copilot/hosts.json")
  }
  
  for _, path in ipairs(config_paths) do
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok, data = pcall(vim.fn.json_decode, content)
      if ok and data then
        -- Extract from standard hosts.json structure
        if data["github.com"] and data["github.com"].oauth_token then
          return data["github.com"].oauth_token
        end
      end
    end
  end
  return nil
end

--- Exchange the permanent OAuth token for a temporary Copilot session token
local function refresh_copilot_token(github_token)
  if copilot_token and os.time() < copilot_token_expires then
    return copilot_token
  end

  local cmd = {
    "curl", "-s",
    "-H", "Authorization: token " .. github_token,
    "-H", "Accept: application/json",
    "https://api.github.com/copilot_internal/v2/token"
  }
  
  -- Run curl synchronously to get the token before chatting
  local stdout = vim.fn.system(cmd)
  if vim.v.shell_error == 0 then
    local ok, parsed = pcall(vim.fn.json_decode, stdout)
    if ok and parsed and parsed.token then
      copilot_token = parsed.token
      copilot_token_expires = parsed.expires_at or (os.time() + 1500)
      return copilot_token
    end
  end
  return nil
end

--- Start polling for the token after giving the user the device code
local function poll_for_token(device_code, interval, max_attempts, on_chunk, on_done)
  if max_attempts <= 0 then
    on_chunk("\n⚠️ **Timeout**: Login process timed out. Try again later.\n")
    if on_done then on_done() end
    return
  end

  local poll_cmd = {
    "curl", "-s", "-X", "POST",
    "https://github.com/login/oauth/access_token",
    "-H", "Accept: application/json",
    "-d", "client_id=" .. copilot_client_id .. "&device_code=" .. device_code .. "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
  }

  local stdout_data = {}
  
  vim.fn.jobstart(poll_cmd, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        table.insert(stdout_data, line)
      end
    end,
    on_exit = function()
      local result = table.concat(stdout_data, "")
      local ok, parsed = pcall(vim.fn.json_decode, result)
      
      if ok and parsed then
        if parsed.access_token then
          -- Auto-save the token so future launches work automatically!
          local config_dir = vim.fn.expand("~/.config/github-copilot")
          vim.fn.mkdir(config_dir, "p")
          local hosts_file = config_dir .. "/hosts.json"
          
          local hosts_data = {}
          local f_in = io.open(hosts_file, "r")
          if f_in then
            local content = f_in:read("*a")
            f_in:close()
            local parse_ok, cur_data = pcall(vim.fn.json_decode, content)
            if parse_ok and type(cur_data) == "table" then hosts_data = cur_data end
          end
          
          hosts_data["github.com"] = hosts_data["github.com"] or {}
          hosts_data["github.com"].user = "copilot_user" 
          hosts_data["github.com"].oauth_token = parsed.access_token
          
          local f_out = io.open(hosts_file, "w")
          if f_out then
            f_out:write(vim.fn.json_encode(hosts_data))
            f_out:close()
          end
          
          on_chunk("\n✅ **Success!** You are now logged into GitHub Copilot. Please hit Enter to run your prompt again!\n")
          if on_done then on_done() end
        elseif parsed.error == "authorization_pending" then
          -- User hasn't finished typing the code, keep checking
          vim.defer_fn(function() poll_for_token(device_code, interval, max_attempts - 1, on_chunk, on_done) end, interval * 1000)
        elseif parsed.error == "slow_down" then
          -- GitHub says we're polling too fast, back off
          vim.defer_fn(function() poll_for_token(device_code, interval + 5, max_attempts - 1, on_chunk, on_done) end, (interval + 5) * 1000)
        elseif parsed.error == "expired_token" then
          on_chunk("\n⚠️ **Error**: The device code expired. Please run the chat again to get a new code.\n")
          if on_done then on_done() end
        else
          -- Unknown error
          on_chunk("\n⚠️ **Error**: " .. (parsed.error_description or parsed.error or "Unknown error occurred.") .. "\n")
          if on_done then on_done() end
        end
      else
        -- If JSON failed to parse for some reason, just retry
        vim.defer_fn(function() poll_for_token(device_code, interval, max_attempts - 1, on_chunk, on_done) end, interval * 1000)
      end
    end
  })
end

--- Start the GitHub Device OAuth Flow to get an access token
--- @param on_chunk function
--- @param on_done function
local function auth_device_flow(on_chunk, on_done)
  local auth_cmd = {
    "curl", "-s", "-X", "POST",
    "https://github.com/login/device/code",
    "-H", "Accept: application/json",
    "-d", "client_id=" .. copilot_client_id .. "&scope=read:user"
  }
  
  local stdout = vim.fn.system(auth_cmd)
  local ok, parsed = pcall(vim.fn.json_decode, stdout)
  
  if ok and parsed and parsed.user_code then
    on_chunk("⚠️ **No Copilot token found!** Initiating login sequence...\n\n")
    on_chunk("Please open: " .. parsed.verification_uri .. "\n")
    on_chunk("And enter the code: **" .. parsed.user_code .. "**\n\n")
    on_chunk("*(Waiting for you to authorize in your browser...)*\n")
    
    local interval = parsed.interval or 5
    poll_for_token(parsed.device_code, interval, 40, on_chunk, on_done)
  else
    on_chunk("⚠️ **Error**: Failed to contact GitHub for authentication.\n")
    if on_done then on_done() end
  end
end

--- Fetch response from the GitHub Copilot Chat API using streaming curl
--- @param prompt string The user prompt
--- @param on_chunk function Callback for each text chunk
--- @param on_done function Callback when finished
function M.stream_response(prompt, on_chunk, on_done)
  local github_token = get_github_oauth_token()
  
  if not github_token then
    auth_device_flow(on_chunk, on_done)
    return
  end

  local session_token = refresh_copilot_token(github_token)
  if not session_token then
    on_chunk("⚠️ **Error**: Failed to negotiate a Copilot session token with GitHub.\n")
    if on_done then on_done() end
    return
  end

  -- Payload matching Copilot Chat interface
  local payload = {
    model = "gpt-4o", -- The standard model used by GitHub Copilot chat
    messages = {
      { role = "system", content = "You are an AI programming assistant integrated into a Neovim editor." },
      { role = "user", content = prompt }
    },
    stream = true
  }

  local json_payload = vim.fn.json_encode(payload)
  
  -- Request to the Copilot Chat Completions endpoint
  local cmd = {
    "curl",
    "-N", "-s", "-X", "POST",
    "https://api.githubcopilot.com/chat/completions",
    "-H", "Authorization: Bearer " .. session_token,
    "-H", "Content-Type: application/json",
    "-H", "Editor-Version: Neovim/0.10",
    "-H", "Editor-Plugin-Version: copilot-chat.nvim/0.1.0",
    "-H", "OpenAI-Organization: github-copilot",
    "-d", json_payload
  }

  -- Launch async job to stream the JSON data
  local debug_output = {}
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data_lines)
      for _, line in ipairs(data_lines) do
        if line and line ~= "" then
          table.insert(debug_output, line)
          if line:match("^data: ") then
            local json_str = line:gsub("^data: ", "")
            if json_str == "[DONE]" then
              -- Expected end of stream
            else
              local ok, parsed = pcall(vim.fn.json_decode, json_str)
              if ok and parsed and parsed.choices and parsed.choices[1].delta and parsed.choices[1].delta.content then
                on_chunk(parsed.choices[1].delta.content)
              end
            end
          else
            -- ⚠️ ALWAYS print any non-chunk line literally to the screen so we can see if it's a 401 HTML page or plain text error!
            on_chunk("\n`" .. line .. "`\n")
          end
        end
      end
    end,
    on_stderr = function(_, data_lines)
      for _, line in ipairs(data_lines) do
        if line and line ~= "" then
          on_chunk("\n⚠️ **Curl Error**: `" .. line .. "`\n")
        end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        on_chunk("\n⚠️ **Process exited with code**: `" .. tostring(code) .. "`\n")
      end
      if #debug_output == 0 then
        on_chunk("\n⚠️ **Error**: Received completely empty response from server.\n")
      end
      if on_done then on_done() end
    end,
  })
end

return M
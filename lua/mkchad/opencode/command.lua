-- Entry point for mkchad-opencode-server.  It is executed with `nvim -u NONE`
-- by the installed container wrapper and therefore must not load MkChad's
-- init.lua or any plugins.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))
package.path = vim.fs.joinpath(config_root, "lua", "?.lua") .. ";" .. package.path

local function arguments_after_entrypoint()
  local argv = vim.v.argv
  local entry_index
  for index, value in ipairs(argv) do
    if value == source then
      entry_index = index
    end
  end
  if not entry_index then
    return {}
  end
  local arguments = {}
  for index = entry_index + 1, #argv do
    if argv[index] ~= "--" then
      table.insert(arguments, argv[index])
    end
  end
  return arguments
end

local function has_control(value)
  return type(value) ~= "string" or value:find "[%z\1-\31\127]" ~= nil
end

local function usage()
  return table.concat({
    "Usage: mkchad-opencode-server start [--json]",
    "       mkchad-opencode-server status [--json] [--host-evidence-v1 BASE64URL]",
    "       mkchad-opencode-server stop [--json]",
    "       mkchad-opencode-server clear [--json]",
    "       mkchad-opencode-server kill [--json]",
    "       mkchad-opencode-server --help",
  }, "\n")
end

local arguments = arguments_after_entrypoint()
local command = arguments[1]
local json_mode = false
local host_evidence
local usage_error
if command == "--help" and #arguments == 1 then
  io.stdout:write(usage() .. "\n")
  io.stdout:flush()
  vim.cmd "qa!"
  return
elseif
  command ~= "start"
  and command ~= "status"
  and command ~= "stop"
  and command ~= "clear"
  and command ~= "kill"
then
  usage_error = "expected start, status, stop, clear, kill, or --help"
else
  local index = 2
  while index <= #arguments do
    local value = arguments[index]
    if value == "--json" and not json_mode then
      json_mode = true
    elseif value == "--host-evidence-v1" and command == "status" and host_evidence == nil then
      local payload = arguments[index + 1]
      if not payload or payload == "" or payload:sub(1, 2) == "--" then
        usage_error = "--host-evidence-v1 requires a base64url payload"
      else
        host_evidence = payload
        index = index + 1
      end
    else
      usage_error = "expected only --json and one --host-evidence-v1 payload after status"
    end
    index = index + 1
  end
end
for _, value in ipairs(arguments) do
  if has_control(value) then
    usage_error = "arguments must not contain control characters"
  end
end
if usage_error then
  io.stderr:write("mkchad-opencode-server: " .. usage_error .. "\n" .. usage() .. "\n")
  io.stderr:flush()
  vim.cmd "cquit 2"
  return
end

local function bounded_message(value)
  value = tostring(value or "operation failed"):gsub("[%z\1-\31\127]", " ")
  return value:sub(1, 1024)
end

local function error_code(message)
  message = message:lower()
  if message:find("configuration", 1, true) then
    return "configuration_invalid"
  elseif message:find("differs from active", 1, true) then
    return "mode_mismatch"
  elseif message:find("launch intent", 1, true) then
    return "launch_intent_blocked"
  elseif message:find("unverifiable", 1, true) then
    return "process_unverifiable"
  elseif message:find("broker control", 1, true) then
    return "broker_control_unavailable"
  elseif message:find("broker activation", 1, true) then
    return "broker_activation_failed"
  end
  return "lifecycle_failed"
end

local function result_state(state)
  if not state then
    return nil
  end
  local transport = state.schema == 2 and "tls-proxy" or state.transport
  if
    type(state.url) ~= "string"
    or type(state.generation) ~= "string"
    or (transport ~= "tls-proxy" and transport ~= "loopback-http")
  then
    return nil
  end
  local ca_cert = transport == "tls-proxy" and state.ca_path or vim.NIL
  if transport == "tls-proxy" and type(ca_cert) ~= "string" then
    return nil
  end
  local server_version = state.backend and state.backend.server_version
  if server_version ~= nil and (has_control(server_version) or #server_version > 128) then
    return nil
  end
  return {
    url = state.url,
    transport = transport,
    generation = state.generation,
    ca_cert = ca_cert,
    server_version = server_version,
  }
end

local function human_status(status, state, message, inventory)
  state = type(state) == "table" and state or nil
  local lines = {
    "Command status: " .. status,
    "URL: " .. (state and state.url or "inactive"),
    "Transport: " .. (state and state.transport or "inactive"),
    "Generation: " .. (state and state.generation or "inactive"),
    "Server version: " .. (state and state.server_version or "unknown"),
  }
  if state and state.transport == "tls-proxy" then
    table.insert(lines, "CA certificate: " .. state.ca_cert)
  end
  if message and status ~= "healthy" and status ~= "inactive" then
    table.insert(lines, "Command diagnostic: " .. bounded_message(message))
  end
  if inventory then
    for line in require("mkchad.opencode.inventory").human(inventory):gmatch "[^\n]+" do
      table.insert(lines, line)
    end
  end
  return table.concat(lines, "\n")
end

local completed = false
local function finish(exit_code, ok, status, state, message, diagnostic_code, inventory)
  if completed then
    return
  end
  completed = true
  if json_mode then
    local result = { schema = 1, ok = ok, command = command, status = status }
    if ok then
      result.state = state or vim.NIL
      if message and status ~= "healthy" and status ~= "inactive" then
        result.diagnostic = {
          code = diagnostic_code or ("observation_" .. status),
          message = bounded_message(message),
        }
      end
      if inventory then
        result.inventory = inventory
      end
    else
      result.error = { code = error_code(message or ""), message = bounded_message(message) }
      if inventory then
        result.inventory = inventory
      end
    end
    io.stdout:write(vim.json.encode(result) .. "\n")
  elseif ok and command == "status" then
    io.stdout:write(human_status(status, state, message, inventory) .. "\n")
  elseif ok then
    io.stdout:write(command .. ": " .. status .. "\n")
  else
    io.stderr:write("mkchad-opencode-server: " .. bounded_message(message) .. "\n")
  end
  io.stdout:flush()
  io.stderr:flush()
  vim.cmd(exit_code == 0 and "qa!" or "cquit " .. exit_code)
end

local loaded, lifecycle = xpcall(function()
  return require "mkchad.opencode.lifecycle"
end, function()
  return "unable to load the installed MkChad lifecycle assets"
end)
if not loaded then
  finish(1, false, "blocked", nil, lifecycle)
  return
end

local function finish_inactive(ok, message)
  if ok then
    finish(0, true, "inactive", nil)
  else
    finish(1, false, "blocked", nil, message)
  end
end

local status_inventory
if command == "start" then
  lifecycle.ensure(function(ok, message, state)
    local stable_state = result_state(state)
    if ok and stable_state then
      finish(0, true, "healthy", stable_state)
    else
      finish(1, false, "blocked", nil, message or "lifecycle returned an invalid state")
    end
  end)
elseif command == "status" then
  local collectors_loaded, collectors = xpcall(function()
    return require "mkchad.opencode.inventory_collectors"
  end, function()
    return nil
  end)
  local lifecycle_result
  local inventory_ready = not collectors_loaded
  local function settle_status()
    if not lifecycle_result or not inventory_ready then
      return
    end
    local status, state, message, diagnostic_code = unpack(lifecycle_result)
    local stable_state = result_state(state)
    if status == "healthy" and not stable_state then
      finish(
        0,
        true,
        "blocked",
        nil,
        message or "lifecycle returned an invalid state",
        "invalid_lifecycle_state",
        status_inventory
      )
      return
    end
    finish(0, true, status, stable_state, message, diagnostic_code, status_inventory)
  end
  local finish_collection
  if collectors_loaded then
    local started, result = pcall(collectors.collect_async, {
      config_root = config_root,
      host_evidence = host_evidence,
      probe = lifecycle.probe,
    }, function(value)
      status_inventory = value
      inventory_ready = true
      settle_status()
    end)
    if started then
      finish_collection = result
    else
      finish_collection = function(projection)
        status_inventory = collectors.fallback(projection)
        inventory_ready = true
      end
    end
  end
  lifecycle.status(function(status, state, message, diagnostic_code, projection)
    lifecycle_result = { status, state, message, diagnostic_code }
    projection = projection or lifecycle.projection and lifecycle.projection(status, state) or {}
    if finish_collection then
      finish_collection(projection)
    elseif collectors_loaded then
      local ok, value = pcall(collectors.collect, {
        config_root = config_root,
        host_evidence = host_evidence,
        lifecycle = projection,
      })
      status_inventory = ok and value or nil
      if not status_inventory then
        status_inventory = collectors.fallback(projection)
      end
      inventory_ready = true
    end
    settle_status()
  end)
elseif command == "stop" then
  lifecycle.stop(finish_inactive)
elseif command == "clear" then
  lifecycle.clear(finish_inactive)
else
  lifecycle.kill(finish_inactive)
end

-- `-l` otherwise exits after the top-level chunk returns, which would tear
-- down the libuv work used by the asynchronous lifecycle before it can publish
-- a result. The lifecycle itself has a 30-second cap; this is only its bounded
-- command-level allowance for scheduling and final JSON emission.
if not vim.wait(35000, function()
  return completed
end, 20) then
  finish(1, false, "blocked", nil, "standalone lifecycle command timed out", nil, status_inventory)
end

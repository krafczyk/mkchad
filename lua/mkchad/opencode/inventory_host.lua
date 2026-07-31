local inventory = require "mkchad.opencode.inventory"
local M = {}

local function bounded(value, maximum)
  return type(value) == "string"
    and #value > 0
    and #value <= maximum
    and not value:find "[%z\1-\31\127]"
    and pcall(vim.str_utfindex, value)
end

function M.decode(payload)
  if payload == nil then
    return nil, "omitted"
  end
  if type(payload) ~= "string" or #payload == 0 or #payload > 6144 or payload:find "[^A-Za-z0-9_-]" then
    return nil, "invalid"
  end
  if #payload % 4 == 1 then
    return nil, "invalid"
  end
  local encoded = payload:gsub("-", "+"):gsub("_", "/")
  encoded = encoded .. string.rep("=", (4 - #encoded % 4) % 4)
  local decoded_base64, raw = pcall(vim.base64.decode, encoded)
  if not decoded_base64 then
    return nil, "invalid"
  end
  local canonical = vim.base64.encode(raw or ""):gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
  if canonical ~= payload then
    return nil, "invalid"
  end
  local decoded, err = inventory.decode_json(raw or "", 4096)
  if not decoded or type(decoded) ~= "table" or decoded.schema ~= 1 then
    return nil, err or "invalid"
  end
  local allowed = { schema = true, container_runtime = true, selected_image = true, persisted_instance = true }
  for key in pairs(decoded) do
    if not allowed[key] then
      return nil, "invalid"
    end
  end
  local states = { present = true, absent = true, unavailable = true, not_discoverable = true }
  local runtime_families = { apptainer = true, singularity = true }
  local function complete_version(value)
    return bounded(value, 128) and value:match "^[0-9][0-9A-Za-z.+_-]*$" ~= nil
  end
  local function host_stat(value)
    return bounded(value, 128)
      and value:match "^%d+:%d+:%d+:%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.[0-9]+ [+-]%d%d%d%d:%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.[0-9]+ [+-]%d%d%d%d$"
        ~= nil
  end
  for _, key in ipairs { "container_runtime", "selected_image", "persisted_instance" } do
    local item = decoded[key]
    if item and (type(item) ~= "table" or not states[item.state]) then
      return nil, "invalid"
    end
    if item and item.state == "present" then
      if key == "container_runtime" then
        if not runtime_families[item.family] or not complete_version(item.version) then
          return nil, "invalid"
        end
        local has_kind, has_identity = item.executable_identity_kind ~= nil, item.executable_identity ~= nil
        if
          has_kind ~= has_identity
          or has_kind
            and (item.executable_identity_kind ~= "host-file-stat-v1" or not host_stat(item.executable_identity))
        then
          return nil, "invalid"
        end
        for field in pairs(item) do
          if
            field ~= "state"
            and field ~= "family"
            and field ~= "version"
            and field ~= "executable_identity_kind"
            and field ~= "executable_identity"
          then
            return nil, "invalid"
          end
        end
      elseif item.identity_kind ~= "host-file-stat-v1" or not host_stat(item.identity) then
        return nil, "invalid"
      else
        if
          item.label ~= nil
          and (key ~= "persisted_instance" or not bounded(item.label, 64) or not item.label:match "^[A-Za-z0-9._-]+$")
        then
          return nil, "invalid"
        end
        for field in pairs(item) do
          if field ~= "state" and field ~= "identity_kind" and field ~= "identity" and field ~= "label" then
            return nil, "invalid"
          end
          if field == "label" and key ~= "persisted_instance" then
            return nil, "invalid"
          end
        end
      end
    elseif item then
      for field in pairs(item) do
        if field ~= "state" then
          return nil, "invalid"
        end
      end
    end
  end
  return decoded
end

return M

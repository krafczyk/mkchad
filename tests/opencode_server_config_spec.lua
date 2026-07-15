local config = assert(arg[1], "pass the MkChad OpenCode config path")
local server_config = assert(arg[2], "pass an isolated server config path")

assert(vim.fn.mkdir(vim.fs.dirname(server_config), "p", 448) ~= 0 or vim.uv.fs_stat(vim.fs.dirname(server_config)))

local listener = assert(vim.uv.new_tcp())
assert(listener:bind("127.0.0.1", 0) == 0)
assert(listener:listen(1, function() end) == 0)
local occupied_port = listener:getsockname().port
local secret = "config-secret-not-for-output"
local lifecycle

local function write_config(value, mode)
  vim.fn.writefile({ vim.json.encode(value) }, server_config)
  assert(vim.uv.fs_chmod(server_config, mode or 384))
end

local function write_raw(value, mode)
  vim.fn.writefile(value and { value } or {}, server_config)
  assert(vim.uv.fs_chmod(server_config, mode or 384))
end

local function expect_config_error(fragment)
  local loaded, err = lifecycle.load_server_config()
  assert(not loaded and err:find(fragment, 1, true), err)
  assert(not err:find(secret, 1, true), "validation failure exposed the configured password")
  local port, _, port_err = lifecycle.select_port(nil)
  assert(not port and port_err:find(fragment, 1, true), port_err)
end

vim.env.OPENCODE_PORT = nil
vim.env.OPENCODE_SERVER_USERNAME = nil
vim.env.OPENCODE_SERVER_PASSWORD = nil
write_config({ port = occupied_port, username = "configured-user", password = secret })

vim.g.mkchad_opencode_test_api = true
vim.g.mkchad_opencode_test_server_config = server_config
dofile(config)
lifecycle = vim.g.mkchad_opencode_test_api

assert(vim.env.OPENCODE_PORT == tostring(occupied_port))
assert(vim.env.OPENCODE_SERVER_USERNAME == "configured-user")
assert(vim.env.OPENCODE_SERVER_PASSWORD == secret)
assert(lifecycle.server_setting_source("OPENCODE_PORT") == "config file")
assert(lifecycle.server_setting_source("OPENCODE_SERVER_PASSWORD") == "config file")
assert(lifecycle.requested_transport() == "tls-proxy", "absent tls_proxy must preserve TLS")

vim.env.OPENCODE_PORT = "45678"
vim.env.OPENCODE_SERVER_PASSWORD = "replacement-secret"
assert(lifecycle.server_setting_source("OPENCODE_PORT") == "environment")
assert(lifecycle.server_setting_source("OPENCODE_SERVER_PASSWORD") == "environment")
vim.env.OPENCODE_PORT = nil
vim.env.OPENCODE_SERVER_USERNAME = nil
vim.env.OPENCODE_SERVER_PASSWORD = nil

write_config({ port = occupied_port, tls_proxy = false })
assert(lifecycle.load_server_config())
assert(lifecycle.requested_transport() == "loopback-http", "false tls_proxy was not retained")
write_config({ port = occupied_port, tls_proxy = true })
assert(lifecycle.load_server_config())
assert(lifecycle.requested_transport() == "tls-proxy", "true tls_proxy was not retained")
for _, value in ipairs({ '"false"', "0", "null", "[]", "{}" }) do
  write_raw('{"tls_proxy":' .. value .. "}")
  expect_config_error("tls_proxy must be a JSON Boolean")
end
write_config({ port = occupied_port })
assert(lifecycle.load_server_config())
assert(lifecycle.requested_transport() == "tls-proxy", "absent tls_proxy stopped defaulting to TLS")

local selected, _, conflict_err = lifecycle.select_port(nil)
assert(not selected and conflict_err:find("Configured OpenCode port", 1, true), conflict_err)
assert(conflict_err:find("occupied", 1, true), conflict_err)
assert(not conflict_err:find(secret, 1, true), "port failure exposed the configured password")
assert(lifecycle.read_state() == nil, "occupied configured port changed lifecycle state")

vim.env.OPENCODE_PORT = "45678"
vim.env.OPENCODE_SERVER_USERNAME = "environment-user"
vim.env.OPENCODE_SERVER_PASSWORD = "environment-secret"
write_config({ port = occupied_port, username = "ignored-user", password = "ignored-secret" })
assert(lifecycle.load_server_config())
assert(vim.env.OPENCODE_PORT == "45678")
assert(vim.env.OPENCODE_SERVER_USERNAME == "environment-user")
assert(vim.env.OPENCODE_SERVER_PASSWORD == "environment-secret")
assert(lifecycle.server_setting_source("OPENCODE_PORT") == "environment")
assert(lifecycle.server_setting_source("OPENCODE_SERVER_PASSWORD") == "environment")

write_config({ port = occupied_port, password = secret }, 420)
expect_config_error("mode 0600")

write_config({ port = occupied_port, password = secret, unexpected = true })
expect_config_error("contains an unsupported key")

write_raw("{")
expect_config_error("one JSON object")

write_config({ port = 0, password = secret })
expect_config_error("port must be an integer")

write_config({ port = occupied_port, username = "invalid:user", password = secret })
expect_config_error("username must be")

write_config({ port = occupied_port, password = "invalid\npassword" })
expect_config_error("password must be")

write_raw(nil)
expect_config_error("between 1 byte and 64 KiB")

write_raw(string.rep("x", 64 * 1024 + 1))
expect_config_error("between 1 byte and 64 KiB")

vim.uv.fs_unlink(server_config)
local symlink_target = server_config .. ".target"
vim.fn.writefile({ "{}" }, symlink_target)
assert(vim.uv.fs_chmod(symlink_target, 384))
assert(vim.uv.fs_symlink(symlink_target, server_config))
expect_config_error("regular file")
vim.uv.fs_unlink(server_config)
vim.uv.fs_unlink(symlink_target)

vim.env.OPENCODE_PORT = nil
vim.env.OPENCODE_SERVER_USERNAME = nil
vim.env.OPENCODE_SERVER_PASSWORD = nil
assert(lifecycle.load_server_config())
assert(lifecycle.requested_transport() == "tls-proxy")
listener:close()

print("opencode server config tests passed")

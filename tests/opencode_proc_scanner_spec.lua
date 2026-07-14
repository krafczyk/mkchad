local config = assert(arg[1], "pass the MkChad config path")
local root = assert(arg[2], "pass a temporary fixture directory")
vim.g.mkchad_opencode_test_api = true
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
assert(vim.fn.mkdir(root, "p", 448) ~= 0 or vim.uv.fs_stat(root))

local tcp_path = vim.fs.joinpath(root, "tcp")
local tcp6_path = vim.fs.joinpath(root, "tcp6")
local tcp_header = "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
local tcp6_header = "sl local_address remote_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
local port = 40000

local function write(path, content)
  local fd = assert(vim.uv.fs_open(path, "w", 384))
  assert(vim.uv.fs_write(fd, content, 0))
  assert(vim.uv.fs_close(fd))
end

local function row(index, family, row_port, inode, replacements)
  local ipv6 = family == "tcp6"
  local fields = {
    tostring(index) .. ":",
    (ipv6 and "00000000000000000000000001000000" or "0100007F")
      .. ":"
      .. string.format("%04X", row_port),
    (ipv6 and "00000000000000000000000000000000" or "00000000")
      .. ":0000",
    "0A",
    "00000000:00000000",
    "00:00000000",
    "00000000",
    "1000",
    "0",
    tostring(inode),
    "1",
    "0000000000000000",
    "100",
    "0",
    "0",
    "10",
    "0",
  }
  for field, value in pairs(replacements or {}) do
    fields[field] = value
  end
  return table.concat(fields, " ") .. "\n"
end

local function scan(tcp, tcp6)
  write(tcp_path, tcp)
  write(tcp6_path, tcp6)
  return lifecycle.find_unique_listener_inode(port, { tcp_path, tcp6_path })
end

local large = { tcp_header }
for index = 0, 149 do
  table.insert(
    large,
    row(index, "tcp", index == 120 and port or port + 1, index == 120 and 4242 or 1000 + index)
  )
end
assert(#table.concat(large) > 8192)
assert(scan(table.concat(large), tcp6_header) == "4242", "a listener beyond the old 8 KiB prefix was not found")

local match = row(0, "tcp", port, 4242)
assert(scan(tcp_header .. match, tcp6_header) == "4242")
assert(not scan(tcp_header .. match .. row(1, "tcp", port + 1, 5252, { [7] = "malformed" }), tcp6_header))
assert(not scan(tcp_header .. row(0, "tcp", port, 4242, {
  [2] = "00000000000000000000000001000000:" .. string.format("%04X", port),
}), tcp6_header))
assert(not scan(match, tcp6_header))
assert(not scan("", tcp6_header))
assert(not scan(tcp_header .. tcp_header, tcp6_header))
assert(not scan(tcp_header .. match:sub(1, -2), tcp6_header), "a match on a truncated final line was accepted")
assert(not scan(tcp_header .. match .. row(1, "tcp", port, 5252), tcp6_header), "duplicate listeners were accepted")
assert(
  not scan(tcp_header .. match, tcp6_header .. row(0, "tcp6", port, 5252)),
  "cross-table duplicate listeners were accepted"
)
assert(not scan(tcp_header .. match, ""), "a match was accepted with an empty other table")
assert(not scan(tcp_header .. match, tcp6_header:sub(1, -2)), "a match was accepted with a truncated other header")
assert(not scan(tcp_header .. match, tcp6_header .. tcp6_header), "a repeated other-table header was accepted")

local listener = assert(vim.uv.new_tcp())
assert(listener:bind("127.0.0.1", 0) == 0)
assert(listener:listen(1, function() end) == 0)
local listener_port = assert(listener:getsockname()).port
assert(vim.wait(2000, function()
  return lifecycle.process_listens_on_port(vim.fn.getpid(), listener_port)
end, 20), "production process_listens_on_port did not prove a controlled listener")
listener:close()

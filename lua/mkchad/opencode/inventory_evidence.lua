local M = {}
local uv = vim.uv
local bit = bit

local function same_stat(left, right)
  if not left or not right then
    return false
  end
  local function timestamp_equal(a, b)
    return a and b and a.sec == b.sec and a.nsec == b.nsec
  end
  return left.type == right.type
    and left.dev == right.dev
    and left.ino == right.ino
    and left.uid == right.uid
    and left.gid == right.gid
    and left.mode == right.mode
    and left.nlink == right.nlink
    and left.size == right.size
    and timestamp_equal(left.mtime, right.mtime)
    and timestamp_equal(left.ctime, right.ctime)
end

function M.path_within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.validate_ancestors(root, path, expected_uid)
  if not M.path_within(path, root) then
    return false
  end
  local current = root
  local relative = path == root and "" or path:sub(#root + 2)
  for part in relative:gmatch "[^/]+" do
    local stat = uv.fs_lstat(current)
    if not stat or stat.type ~= "directory" or stat.uid ~= expected_uid or bit.band(stat.mode, 18) ~= 0 then
      return false
    end
    current = vim.fs.joinpath(current, part)
  end
  return true
end

function M.safe_snapshot(path, root, expected_uid, expected_type)
  if not M.validate_ancestors(root, path, expected_uid) then
    return nil, "unsafe"
  end
  local stat = uv.fs_lstat(path)
  if not stat then
    return nil, "missing"
  end
  if stat.type ~= expected_type or stat.uid ~= expected_uid or bit.band(stat.mode, 18) ~= 0 then
    return nil, "unsafe"
  end
  if expected_type == "file" and stat.nlink ~= 1 then
    return nil, "unsafe"
  end
  return stat
end

function M.snapshot_unchanged(path, snapshot)
  return same_stat(snapshot, uv.fs_lstat(path))
end

function M.directory_entries(path, root, maximum, expected_uid)
  local snapshot, snapshot_err = M.safe_snapshot(path, root, expected_uid, "directory")
  if not snapshot then
    return nil, snapshot_err
  end
  local scanner = uv.fs_scandir(path)
  if not scanner then
    return nil, "unavailable"
  end
  local names = {}
  while true do
    local name = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    if #names >= maximum then
      return nil, "oversized"
    end
    if not name:match "^[ -~]+$" or name == "." or name == ".." then
      return nil, "unsafe"
    end
    table.insert(names, name)
  end
  table.sort(names)
  if not M.snapshot_unchanged(path, snapshot) then
    return nil, "raced"
  end
  local rescanned = uv.fs_scandir(path)
  if not rescanned then
    return nil, "raced"
  end
  local current = {}
  while true do
    local name = uv.fs_scandir_next(rescanned)
    if not name then
      break
    end
    table.insert(current, name)
  end
  table.sort(current)
  if not vim.deep_equal(names, current) then
    return nil, "raced"
  end
  return names
end

function M.read_regular(path, root, maximum, expected_uid)
  if not uv.fs_lstat(root) then
    return nil, "missing"
  end
  if not M.validate_ancestors(root, path, expected_uid) then
    return nil, "unsafe"
  end
  local before = uv.fs_lstat(path)
  if not before then
    return nil, "missing"
  end
  if
    before.type ~= "file"
    or before.uid ~= expected_uid
    or before.nlink ~= 1
    or before.size > maximum
    or bit.band(before.mode, 18) ~= 0
  then
    return nil, "unsafe"
  end
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return nil, "unavailable"
  end
  local opened = uv.fs_fstat(fd)
  if not same_stat(before, opened) then
    uv.fs_close(fd)
    return nil, "raced"
  end
  local data = uv.fs_read(fd, before.size, 0)
  local after_fd = uv.fs_fstat(fd)
  uv.fs_close(fd)
  local after_path = uv.fs_lstat(path)
  if not data or not same_stat(before, after_fd) or not same_stat(before, after_path) then
    return nil, "raced"
  end
  return data
end

local function u32be(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function u64be(value)
  return "\0\0\0\0" .. u32be(value)
end

function M.digest_profile(root, profile, expected_uid, deadline_ns)
  local started = uv.hrtime()
  local function expired()
    return deadline_ns and uv.hrtime() >= deadline_ns or (uv.hrtime() - started) / 1000000 > profile.max_elapsed_ms
  end
  if profile.framing == "raw-file-bytes-v1" then
    if expired() then
      return nil, "timed_out"
    end
    local data, err =
      M.read_regular(vim.fs.joinpath(root, profile.included_roots[1]), root, profile.max_per_file_bytes, expected_uid)
    if not data then
      return nil, err
    end
    local digest = vim.fn.sha256(data)
    if expired() then
      return nil, "timed_out"
    end
    return digest
  end

  local files, directories, bytes, entries = {}, {}, 0, 0
  local exclusions = {}
  for _, excluded in ipairs(profile.exclusions) do
    exclusions[excluded] = true
  end
  local function visit(relative)
    if exclusions[relative] then
      return true
    end
    if expired() then
      return nil, "timed_out"
    end
    local path = vim.fs.joinpath(root, relative)
    local stat = uv.fs_lstat(path)
    if not stat or stat.uid ~= expected_uid then
      return nil, stat and "unsafe" or "missing"
    end
    if stat.type == "file" then
      if stat.nlink ~= 1 or stat.size > profile.max_per_file_bytes then
        return nil, "unsafe"
      end
      table.insert(files, relative)
      bytes = bytes + stat.size
      if #files > profile.max_regular_files or bytes > profile.max_total_bytes then
        return nil, "oversized"
      end
      return true
    end
    if stat.type ~= "directory" then
      return nil, "unsafe"
    end
    if bit.band(stat.mode, 18) ~= 0 then
      return nil, "unsafe"
    end
    local scanner = uv.fs_scandir(path)
    if not scanner then
      return nil, "unavailable"
    end
    local names = {}
    while true do
      local name, kind = uv.fs_scandir_next(scanner)
      if not name then
        break
      end
      entries = entries + 1
      if entries > math.min(profile.max_regular_files * 4 + 32, 16384) then
        return nil, "oversized"
      end
      if expired() then
        return nil, "timed_out"
      end
      if not name:match "^[ -~]+$" or name == "." or name == ".." or kind == "link" then
        return nil, "unsafe"
      end
      table.insert(names, name)
    end
    table.sort(names)
    table.insert(directories, { path = path, stat = stat, names = vim.deepcopy(names) })
    for _, name in ipairs(names) do
      local child = relative == "" and name or relative .. "/" .. name
      local ok, err = visit(child)
      if not ok then
        return nil, err
      end
    end
    return true
  end
  for _, relative in ipairs(profile.included_roots) do
    local ok, err = visit(relative)
    if not ok then
      return nil, err
    end
  end
  table.sort(files)
  local framed, actual_bytes = {}, 0
  for _, relative in ipairs(files) do
    if expired() then
      return nil, "timed_out"
    end
    local data, err = M.read_regular(vim.fs.joinpath(root, relative), root, profile.max_per_file_bytes, expected_uid)
    if not data then
      return nil, err
    end
    actual_bytes = actual_bytes + #data
    if actual_bytes > profile.max_total_bytes then
      return nil, "oversized"
    end
    table.insert(framed, u32be(#relative))
    table.insert(framed, relative)
    table.insert(framed, u64be(#data))
    table.insert(framed, data)
  end
  for _, directory in ipairs(directories) do
    if not same_stat(directory.stat, uv.fs_lstat(directory.path)) then
      return nil, "raced"
    end
    local scanner = uv.fs_scandir(directory.path)
    if not scanner then
      return nil, "raced"
    end
    local names = {}
    while true do
      local name = uv.fs_scandir_next(scanner)
      if not name then
        break
      end
      table.insert(names, name)
    end
    table.sort(names)
    if not vim.deep_equal(names, directory.names) then
      return nil, "raced"
    end
  end
  if expired() then
    return nil, "timed_out"
  end
  local digest = vim.fn.sha256(table.concat(framed))
  if expired() then
    return nil, "timed_out"
  end
  return digest
end

return M

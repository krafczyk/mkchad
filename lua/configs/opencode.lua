local uv = vim.uv
local config_source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p")
local config_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(config_source)))
local host = "127.0.0.1"
local preferred_port = 4096
local startup_timeout_ms = 30000
local health_interval_ms = 200
local local_tui_bootstrap_ms = 200
local lock_renew_interval_ms = 3000
local proxy_max_connections = 128
local java21 = "/usr/lib/jvm/java-21-openjdk/bin/java"
local password_warning_shown = false
local lifecycle_reporter
local fence_poll_interval_ms = 20
local fence_acquire_timeout_ms = 1000
local pidfd_helper_timeout_ms = 3000
local subprocess_timeout_ms = 5000
local subprocess_term_grace_ms = 250
local subprocess_output_limit = 64 * 1024
local lifecycle_only = vim.g.mkchad_opencode_lifecycle_only == true
local config_home = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME or "", ".config")
local state_home = vim.env.XDG_STATE_HOME or vim.fs.joinpath(vim.env.HOME or "", ".local", "state")
local server_config_path = vim.g.mkchad_opencode_test_api
    and (vim.g.mkchad_opencode_test_server_config or vim.fs.joinpath(
      "/tmp/opencode-mkchad",
      "mkchad-server-config-test-" .. vim.fn.getpid() .. ".json"
    ))
  or vim.fs.joinpath(config_home, "mkchad", "opencode-server.json")
local server_config_error
local server_config_applied = {}
local server_config_tls_proxy = true
local requested_transport

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
  pcall(ffi.cdef, "int flock(int fd, int operation);")
  pcall(
    ffi.cdef,
    [[
    struct mkchad_statx {
      unsigned int stx_mask;
      unsigned int stx_blksize;
      unsigned long long stx_attributes;
      unsigned int stx_nlink;
      unsigned int stx_uid;
      unsigned int stx_gid;
      unsigned short stx_mode;
      unsigned short stx_spare0;
      unsigned long long stx_ino;
      unsigned char stx_rest[216];
    };
  ]]
  )
  pcall(ffi.cdef, "typedef int (*mkchad_statx_fn)(int, const char *, int, unsigned int, void *);")
  pcall(ffi.cdef, "void *dlsym(void *handle, const char *symbol);")
end
local flock_exclusive = 2
local flock_nonblocking = 4
local flock_unlock = 8

local function no_password_warning()
  if requested_transport and requested_transport() == "loopback-http" then
    return "WARNING: OPENCODE_SERVER_PASSWORD is not set. The trusted-host direct HTTP endpoint is accessible to other local users and processes; Basic Auth remains optional and does not encrypt loopback traffic. Set a strong existing password in opencode-server.json or the process environment, then stop and restart the shared server."
  end
  return "WARNING: OPENCODE_SERVER_PASSWORD is not set. TLS authenticates the OpenCode server, not clients; both the public proxy and discoverable internal loopback backend are accessible to other local users. Set a strong existing password in opencode-server.json or the process environment, then stop and restart the shared server."
end

local function notify(message, level)
  if lifecycle_reporter then
    local reporter = lifecycle_reporter
    lifecycle_reporter = nil
    reporter(message, level)
    return
  end
  vim.notify(message, level, { title = "OpenCode" })
end

local function warn_no_password()
  if
    not password_warning_shown and (not vim.env.OPENCODE_SERVER_PASSWORD or vim.env.OPENCODE_SERVER_PASSWORD == "")
  then
    password_warning_shown = true
    notify(no_password_warning(), vim.log.levels.WARN)
  end
end

local function hostname()
  return ((uv.os_gethostname() or "unknown"):gsub("[^%w_.-]", "_"))
end

local function paths()
  local root = vim.fs.joinpath(state_home, "mkchad", "opencode", hostname())
  return {
    root = root,
    state = vim.fs.joinpath(root, "state.json"),
    pending = vim.fs.joinpath(root, "pending.json"),
    launch = vim.fs.joinpath(root, "launch.json"),
    control = vim.fs.joinpath(root, "control.sock"),
    control_quarantine = vim.fs.joinpath(root, "control.quarantine"),
    log = vim.fs.joinpath(root, "server.log"),
    proxy_log = vim.fs.joinpath(root, "proxy.log"),
    fence = vim.fs.joinpath(root, "lifecycle.fence"),
    lock = vim.fs.joinpath(root, "startup.lock"),
    lock_owner = vim.fs.joinpath(root, "startup.lock", "owner.json"),
    tls = vim.fs.joinpath(root, "tls"),
    ca = vim.fs.joinpath(root, "tls", "ca.pem"),
    ca_store = vim.fs.joinpath(root, "tls", "ca.p12"),
    server_store = vim.fs.joinpath(root, "tls", "server.p12"),
    server_cert = vim.fs.joinpath(root, "tls", "server.pem"),
    password = vim.fs.joinpath(root, "tls", "store.password"),
    proxy_source = vim.g.mkchad_opencode_test_api and vim.g.mkchad_opencode_test_proxy_source
      or vim.fs.joinpath(config_root, "java", "MkChadTlsProxy.java"),
    pidfd_helper = vim.g.mkchad_opencode_test_api and vim.g.mkchad_opencode_test_pidfd_helper
      or vim.fs.joinpath(config_root, "scripts", "opencode_pidfd_signal.py"),
    pidfd_python = vim.uv.fs_realpath(vim.fn.exepath "python3") or vim.fn.exepath "python3",
  }
end

local function iso_now()
  return os.date "!%Y-%m-%dT%H:%M:%SZ"
end

local function realtime_ms()
  local seconds, microseconds = uv.gettimeofday()
  return seconds * 1000 + math.floor(microseconds / 1000)
end

local function random_token()
  return table.concat({ tostring(vim.fn.getpid()), tostring(uv.hrtime()), tostring(math.random(0, 0x7fffffff)) }, "-")
end

local function ensure_state_dir()
  local state_paths = paths()
  if state_paths.root:sub(1, 1) ~= "/" or not uv.getuid then
    return nil, "OpenCode authority root must be an absolute current-user path"
  end
  local current = ""
  for component in state_paths.root:gmatch "[^/]+" do
    current = current .. "/" .. component
    local entry, entry_err = uv.fs_lstat(current)
    if not entry then
      if entry_err and not tostring(entry_err):find("ENOENT", 1, true) then
        return nil, "Unable to inspect OpenCode authority path " .. current
      end
      if not uv.fs_mkdir(current, 448) then
        return nil, "Unable to create OpenCode authority directory " .. current
      end
      entry = uv.fs_lstat(current)
    end
    if not entry or entry.type ~= "directory" then
      return nil, "OpenCode authority path is a symlink or non-directory: " .. current
    end
  end
  local root = uv.fs_lstat(state_paths.root)
  if not root or root.type ~= "directory" or root.uid ~= uv.getuid() or root.mode % 512 ~= 448 then
    return nil, "OpenCode authority root ownership or mode is unsafe: " .. state_paths.root
  end
  state_paths.root_identity = { dev = root.dev, ino = root.ino }
  return state_paths
end

local test_hooks = {}

local function authority_root_is_stable(identity)
  local root = identity and uv.fs_lstat(paths().root)
  return root
    and root.type == "directory"
    and uv.getuid
    and root.uid == uv.getuid()
    and root.mode % 512 == 448
    and root.dev == identity.dev
    and root.ino == identity.ino
end

-- Observation must not create the authority root merely to inspect it.
function test_hooks.read_authority_root()
  local root = uv.fs_lstat(paths().root)
  if not root or root.type ~= "directory" or not uv.getuid or root.uid ~= uv.getuid() or root.mode % 512 ~= 448 then
    return nil, "OpenCode authority root is missing or unsafe"
  end
  return { dev = root.dev, ino = root.ino }
end

local fence_fd
local write_private
local release_lock
local valid_argv
local active_subprocesses = {}

local function fence_is_held()
  return fence_fd ~= nil
end

local function release_fence()
  local fd = fence_fd
  fence_fd = nil
  if not fd then
    return
  end
  if ffi_ok then
    pcall(function()
      ffi.C.flock(fd, flock_unlock)
    end)
  end
  uv.fs_close(fd)
end

local function safe_subprocess_callback(callback, ...)
  local arguments = { n = select("#", ...), ... }
  local ok, err = xpcall(function()
    callback(unpack(arguments, 1, arguments.n))
  end, debug.traceback)
  if ok then
    return
  end
  if fence_is_held() then
    if release_lock then
      release_lock()
    else
      release_fence()
    end
  end
  if vim.v.exiting == vim.NIL or vim.v.exiting == 0 then
    vim.schedule(function()
      notify("OpenCode subprocess callback failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

local function subprocess_environment(overrides)
  if not overrides then
    return nil
  end
  local environment = uv.os_environ()
  for name, value in pairs(overrides) do
    environment[name] = value
  end
  local encoded = {}
  for name, value in pairs(environment) do
    table.insert(encoded, name .. "=" .. value)
  end
  return encoded
end

local function valid_subprocess_argv(argv)
  if type(argv) ~= "table" or #argv < 1 or #argv > 128 then
    return false
  end
  for key, value in pairs(argv) do
    if
      type(key) ~= "number"
      or key % 1 ~= 0
      or key < 1
      or key > #argv
      or type(value) ~= "string"
      or value == ""
      or #value > 4096
      or value:find("\0", 1, true)
    then
      return false
    end
  end
  return true
end

local function run_subprocess(argv, options, callback)
  options = options or {}
  local completed = false
  local process
  local pid
  local exit_code
  local exit_signal
  local exited = false
  local stdout_done = false
  local stderr_done = false
  local failure
  local timed_out = false
  local killed = false
  local stdout = {}
  local stderr = {}
  local stdout_size = 0
  local stderr_size = 0
  local stdin_pipe = uv.new_pipe(false)
  local stdout_pipe = uv.new_pipe(false)
  local stderr_pipe = uv.new_pipe(false)
  local deadline_timer = uv.new_timer()
  local kill_timer = uv.new_timer()
  local drain_timer = uv.new_timer()

  local function close_handle(handle)
    if handle and not handle:is_closing() then
      handle:close()
    end
  end

  local function close_timer(timer)
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end

  local function dispatch(result, err)
    if vim.v.exiting ~= vim.NIL and vim.v.exiting ~= 0 then
      if fence_is_held() then
        if release_lock then
          release_lock()
        else
          release_fence()
        end
      end
      return
    end
    vim.schedule(function()
      safe_subprocess_callback(callback, result, err)
    end)
  end

  local function finish()
    if completed or not exited or not stdout_done or not stderr_done then
      return
    end
    completed = true
    if pid then
      active_subprocesses[pid] = nil
    end
    close_timer(deadline_timer)
    close_timer(kill_timer)
    close_timer(drain_timer)
    close_handle(stdin_pipe)
    close_handle(stdout_pipe)
    close_handle(stderr_pipe)
    close_handle(process)
    local result = {
      code = exit_code,
      signal = exit_signal,
      stdout = table.concat(stdout),
      stderr = table.concat(stderr),
      timed_out = timed_out,
      killed = killed,
      pid = pid,
    }
    local err = failure
    if not err and exit_code ~= 0 then
      err = ("%s exited with code %d"):format(vim.fs.basename(argv[1]), exit_code or -1)
    end
    dispatch(result, err)
  end

  local function terminate(reason, timeout)
    if failure or exited then
      return
    end
    failure = reason
    timed_out = timeout or false
    if process and not process:is_closing() then
      pcall(process.kill, process, "sigterm")
      kill_timer:start(subprocess_term_grace_ms, 0, function()
        if not exited and process and not process:is_closing() then
          killed = true
          pcall(process.kill, process, "sigkill")
        end
      end)
    end
  end

  local function consume(target, size_name, chunk)
    if not chunk then
      return
    end
    local current = size_name == "stdout" and stdout_size or stderr_size
    local remaining = subprocess_output_limit - current
    if remaining > 0 then
      table.insert(target, chunk:sub(1, remaining))
    end
    current = current + #chunk
    if size_name == "stdout" then
      stdout_size = current
    else
      stderr_size = current
    end
    if current > subprocess_output_limit then
      terminate(size_name .. " exceeded the bounded subprocess output limit", false)
    end
  end

  if
    not valid_subprocess_argv(argv)
    or type(callback) ~= "function"
    or not stdin_pipe
    or not stdout_pipe
    or not stderr_pipe
    or not deadline_timer
    or not kill_timer
    or not drain_timer
  then
    close_timer(deadline_timer)
    close_timer(kill_timer)
    close_timer(drain_timer)
    close_handle(stdin_pipe)
    close_handle(stdout_pipe)
    close_handle(stderr_pipe)
    dispatch(nil, "invalid bounded subprocess request or unavailable libuv handle")
    return
  end

  local now = uv.hrtime()
  local local_deadline_ns = now + (options.timeout_ms or subprocess_timeout_ms) * 1000000
  local deadline_ns = options.deadline_ns and math.min(options.deadline_ns, local_deadline_ns) or local_deadline_ns
  local remaining_ms = math.floor((deadline_ns - now) / 1000000)
  if remaining_ms <= 0 then
    close_timer(deadline_timer)
    close_timer(kill_timer)
    close_timer(drain_timer)
    close_handle(stdin_pipe)
    close_handle(stdout_pipe)
    close_handle(stderr_pipe)
    dispatch(nil, "bounded subprocess deadline expired before launch")
    return
  end

  local arguments = {}
  for index = 2, #argv do
    table.insert(arguments, argv[index])
  end
  process, pid = uv.spawn(argv[1], {
    args = arguments,
    cwd = options.cwd,
    env = subprocess_environment(options.env),
    stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
  }, function(code, signal)
    exited = true
    exit_code = code
    exit_signal = signal
    close_timer(deadline_timer)
    close_timer(kill_timer)
    drain_timer:start(subprocess_term_grace_ms, 0, function()
      if not stdout_done or not stderr_done then
        failure = failure or "bounded subprocess pipes did not close after child exit"
        stdout_done = true
        stderr_done = true
        pcall(stdout_pipe.read_stop, stdout_pipe)
        pcall(stderr_pipe.read_stop, stderr_pipe)
        close_handle(stdout_pipe)
        close_handle(stderr_pipe)
        finish()
      end
    end)
    close_handle(process)
    finish()
  end)
  if not process or not pid then
    exited = true
    stdout_done = true
    stderr_done = true
    failure = "unable to start " .. vim.fs.basename(argv[1])
    finish()
    return
  end
  active_subprocesses[pid] = function(shutdown)
    if not exited and process and not process:is_closing() then
      failure = failure
        or (shutdown and "Neovim exited while subprocess was active" or "bounded subprocess was cancelled")
      killed = shutdown or killed
      pcall(process.kill, process, shutdown and "sigkill" or "sigterm")
    end
  end
  stdout_pipe:read_start(function(err, chunk)
    if err then
      terminate("unable to read bounded subprocess stdout", false)
    end
    if chunk then
      consume(stdout, "stdout", chunk)
    else
      stdout_done = true
      close_handle(stdout_pipe)
      finish()
    end
  end)
  stderr_pipe:read_start(function(err, chunk)
    if err then
      terminate("unable to read bounded subprocess stderr", false)
    end
    if chunk then
      consume(stderr, "stderr", chunk)
    else
      stderr_done = true
      close_handle(stderr_pipe)
      finish()
    end
  end)
  local stdin = options.stdin or ""
  stdin_pipe:write(stdin, function(write_err)
    if write_err then
      terminate("unable to write protected bounded subprocess stdin", false)
    end
    if not stdin_pipe:is_closing() then
      stdin_pipe:shutdown(function()
        close_handle(stdin_pipe)
      end)
    end
  end)
  deadline_timer:start(remaining_ms, 0, function()
    terminate("bounded subprocess timed out", true)
  end)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for _, cancel in pairs(active_subprocesses) do
      cancel(true)
    end
    if fence_is_held() then
      if release_lock then
        release_lock()
      else
        release_fence()
      end
    end
  end,
})

local function acquire_fence(callback, deadline_ns)
  if fence_fd then
    callback(false, "nested OpenCode lifecycle fence acquisition was refused")
    return
  end
  if not ffi_ok then
    callback(false, "Linux flock support is unavailable in this Neovim")
    return
  end
  local state_paths, state_err = ensure_state_dir()
  if not state_paths then
    callback(false, state_err)
    return
  end
  local fd, open_err = uv.fs_open(state_paths.fence, "a", 384)
  if not fd then
    callback(false, "Unable to open OpenCode lifecycle fence: " .. (open_err or "unknown error"))
    return
  end
  local closed = false
  local function close_fd()
    if not closed then
      closed = true
      uv.fs_close(fd)
    end
  end
  local fd_stat = uv.fs_fstat(fd)
  local path_stat = uv.fs_stat(state_paths.fence)
  local chmod_ok, chmod_err = uv.fs_chmod(state_paths.fence, 384)
  path_stat = uv.fs_stat(state_paths.fence)
  if
    not fd_stat
    or fd_stat.type ~= "file"
    or not path_stat
    or path_stat.type ~= "file"
    or fd_stat.dev ~= path_stat.dev
    or fd_stat.ino ~= path_stat.ino
    or not chmod_ok
    or path_stat.mode % 512 ~= 384
  then
    close_fd()
    callback(false, "OpenCode lifecycle fence path or permissions are unsafe: " .. (chmod_err or state_paths.fence))
    return
  end
  local function attempt()
    local ok, result = pcall(function()
      return ffi.C.flock(fd, flock_exclusive + flock_nonblocking)
    end)
    if ok and result == 0 then
      closed = true
      fence_fd = fd
      callback(true)
      return
    end
    local errno = ok and ffi.errno() or 0
    if ok and (errno == 4 or errno == 11) and uv.hrtime() < deadline_ns then
      vim.defer_fn(attempt, fence_poll_interval_ms)
      return
    end
    close_fd()
    if ok and errno == 11 then
      callback(false, "Timed out waiting for the OpenCode lifecycle fence")
    else
      callback(false, "Unable to acquire the Linux OpenCode lifecycle fence")
    end
  end
  attempt()
end

local function require_fence(action)
  if not fence_is_held() then
    return nil, "OpenCode lifecycle fence is not held for " .. action
  end
  return true
end

local function run_test_hook(action)
  if not vim.g.mkchad_opencode_test_api then
    return
  end
  local hook = test_hooks[action]
  if not hook then
    return
  end
  test_hooks[action] = nil
  write_private(hook.marker, action, true)
  local deadline = uv.hrtime() + 60 * 1000000000
  while not uv.fs_stat(hook.resume) and uv.hrtime() < deadline do
    uv.sleep(10)
  end
  if not uv.fs_stat(hook.resume) then
    error("OpenCode lifecycle test hook timed out: " .. action)
  end
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local size = uv.fs_fstat(fd).size
  -- procfs reports zero-sized pseudo-files even when cmdline has content.
  if size == 0 then
    size = 8192
  end
  local data = uv.fs_read(fd, size, 0)
  uv.fs_close(fd)
  return data
end

local function monotonic_ms()
  return math.floor(uv.hrtime() / 1000000)
end

local function current_boot_id()
  local value = read_file "/proc/sys/kernel/random/boot_id"
  return value and value:match "^%s*(.-)%s*$" or nil
end

local function is_integer(value, minimum, maximum)
  return type(value) == "number" and value == value and value % 1 == 0 and value >= minimum and value <= maximum
end

local function safe_string(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum and not value:find "[%z\1-\31\127]"
end

local function load_server_config()
  for name, value in pairs(server_config_applied) do
    if vim.env[name] == value then
      vim.env[name] = nil
    end
  end
  server_config_applied = {}
  server_config_error = nil
  server_config_tls_proxy = true

  local config = {}
  local metadata, metadata_err = uv.fs_lstat(server_config_path)
  if not metadata and metadata_err and not tostring(metadata_err):find("ENOENT", 1, true) then
    server_config_error = "cannot be inspected: " .. tostring(metadata_err)
    return nil, server_config_error
  end
  if metadata then
    if metadata.type ~= "file" then
      server_config_error = "must be a regular file"
      return nil, server_config_error
    end
    local fd, open_err = uv.fs_open(server_config_path, "r", 0)
    if not fd then
      server_config_error = "cannot be opened: " .. (open_err or "unknown error")
      return nil, server_config_error
    end
    local stat = uv.fs_fstat(fd)
    if not stat or stat.type ~= "file" then
      uv.fs_close(fd)
      server_config_error = "changed while being opened"
      return nil, server_config_error
    end
    if metadata.dev ~= stat.dev or metadata.ino ~= stat.ino then
      uv.fs_close(fd)
      server_config_error = "changed while being opened"
      return nil, server_config_error
    end
    if stat.mode % 512 ~= 384 then
      uv.fs_close(fd)
      server_config_error = "must have mode 0600"
      return nil, server_config_error
    end
    if uv.getuid and stat.uid ~= uv.getuid() then
      uv.fs_close(fd)
      server_config_error = "must be owned by the current user"
      return nil, server_config_error
    end
    if stat.size < 1 or stat.size > 64 * 1024 then
      uv.fs_close(fd)
      server_config_error = "must contain between 1 byte and 64 KiB"
      return nil, server_config_error
    end
    local content, read_err = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not content or #content ~= stat.size then
      server_config_error = "cannot be read completely: " .. (read_err or "short read")
      return nil, server_config_error
    end
    local decoded, parsed = pcall(vim.json.decode, content)
    if not decoded or type(parsed) ~= "table" or vim.islist(parsed) then
      server_config_error = "must contain one JSON object"
      return nil, server_config_error
    end
    local allowed = { port = true, username = true, password = true, tls_proxy = true }
    for key in pairs(parsed) do
      if not allowed[key] then
        server_config_error = "contains an unsupported key"
        return nil, server_config_error
      end
    end
    if parsed.port ~= nil and not is_integer(parsed.port, 1, 65535) then
      server_config_error = "port must be an integer from 1 through 65535"
      return nil, server_config_error
    end
    if parsed.username ~= nil and (not safe_string(parsed.username, 128) or parsed.username:find(":", 1, true)) then
      server_config_error = "username must be a non-empty control-free string without ':'"
      return nil, server_config_error
    end
    if parsed.password ~= nil and not safe_string(parsed.password, 4096) then
      server_config_error = "password must be a non-empty control-free string"
      return nil, server_config_error
    end
    if parsed.tls_proxy ~= nil and type(parsed.tls_proxy) ~= "boolean" then
      server_config_error = "tls_proxy must be a JSON Boolean"
      return nil, server_config_error
    end
    config = parsed
  end

  server_config_tls_proxy = config.tls_proxy ~= false

  local settings = {
    { name = "OPENCODE_PORT", value = config.port and tostring(config.port) or nil },
    { name = "OPENCODE_SERVER_USERNAME", value = config.username },
    { name = "OPENCODE_SERVER_PASSWORD", value = config.password },
  }
  for _, setting in ipairs(settings) do
    local name, value = setting.name, setting.value
    if (not vim.env[name] or vim.env[name] == "") and value then
      vim.env[name] = value
      server_config_applied[name] = value
    end
  end
  return true
end

load_server_config()

local function server_setting_source(name)
  local value = vim.env[name]
  if not value or value == "" then
    return nil
  end
  return server_config_applied[name] == value and "config file" or "environment"
end

requested_transport = function()
  return server_config_tls_proxy and "tls-proxy" or "loopback-http"
end

local function absolute_path(value)
  return safe_string(value, 4096) and value:sub(1, 1) == "/"
end

local function decimal_identity(value, allow_zero)
  if type(value) ~= "string" or not value:match "^%d+$" or (#value > 1 and value:sub(1, 1) == "0") then
    return false
  end
  if not allow_zero and value == "0" then
    return false
  end
  return #value < 20 or (#value == 20 and value <= "18446744073709551615")
end

valid_argv = function(argv)
  if type(argv) ~= "table" or #argv < 1 or #argv > 128 then
    return false
  end
  for key, value in pairs(argv) do
    if not is_integer(key, 1, #argv) or not safe_string(value, 4096) then
      return false
    end
  end
  return true
end

local function valid_process_record(process, role)
  if
    type(process) ~= "table"
    or not is_integer(process.pid, 1, 2147483647)
    or not is_integer(process.port, 1, 65535)
    or not valid_argv(process.argv)
    or not absolute_path(process.process_executable)
    or not decimal_identity(process.process_executable_dev, true)
    or not decimal_identity(process.process_executable_ino, false)
    or not absolute_path(process.executable)
    or not decimal_identity(process.executable_dev, true)
    or not decimal_identity(process.executable_ino, false)
    or type(process.start_time) ~= "string"
    or #process.start_time > 32
    or not process.start_time:match "^[1-9]%d*$"
    or not absolute_path(process.log)
  then
    return false
  end
  local runtime_path = process.process_executable:gsub(" %(deleted%)$", "")
  if
    runtime_path == process.executable
    and (
      process.process_executable_dev ~= process.executable_dev
      or process.process_executable_ino ~= process.executable_ino
    )
  then
    return false
  end
  if role == "proxy" then
    return process.log == paths().proxy_log
      and absolute_path(process.source)
      and process.source == paths().proxy_source
      and decimal_identity(process.source_dev, true)
      and decimal_identity(process.source_ino, false)
  end
  return process.log == paths().log
    and safe_string(process.local_version, 128)
    and (process.server_version == nil or safe_string(process.server_version, 128))
end

local function valid_generation(value)
  return safe_string(value, 256) and value:match "^[%w_.%+-]+$" ~= nil
end

local function valid_boot_id(value)
  if type(value) ~= "string" then
    return false
  end
  local first, second, third, fourth, fifth =
    value:match "^([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)$"
  return first ~= nil and #first == 8 and #second == 4 and #third == 4 and #fourth == 4 and #fifth == 12
end

local function argv_option(argv, option)
  for index, value in ipairs(argv or {}) do
    if value == option then
      return argv[index + 1]
    end
  end
end

local function valid_role_relationships(state)
  local backend = state.backend
  local backend_launch_seen = false
  for index = 1, #backend.argv - 5 do
    backend_launch_seen = backend_launch_seen or backend.argv[index] == backend.executable
  end
  if
    #backend.argv < 6
    or not backend_launch_seen
    or backend.argv[#backend.argv - 4] ~= "serve"
    or backend.argv[#backend.argv - 3] ~= "--hostname"
    or backend.argv[#backend.argv - 2] ~= host
    or backend.argv[#backend.argv - 1] ~= "--port"
    or backend.argv[#backend.argv] ~= tostring(backend.port)
  then
    return false
  end
  local proxy = state.proxy
  if not proxy then
    return true
  end
  if state.schema == 4 then
    local broker = state.broker
    return broker
      and proxy.port ~= backend.port
      and vim.deep_equal(proxy.argv, {
        proxy.executable,
        "--source",
        "21",
        proxy.source,
        "--broker",
        "--state-root",
        paths().root,
        "--control",
        broker.control_path,
        "--generation",
        state.generation,
        "--boot-id",
        state.boot_id,
        "--backend-executable",
        backend.executable,
        "--backend-version",
        backend.local_version,
        "--backend-port",
        tostring(backend.port),
        "--listen-port",
        tostring(proxy.port),
        "--keystore",
        paths().server_store,
        "--password-file",
        paths().password,
        "--max-connections",
        tostring(proxy_max_connections),
        "--backend-log",
        paths().log,
        "--pidfd-python",
        paths().pidfd_python,
        "--pidfd-helper",
        paths().pidfd_helper,
      })
  end
  return proxy.port ~= backend.port
    and #proxy.argv == 20
    and proxy.argv[1] == proxy.executable
    and proxy.argv[2] == "--source"
    and proxy.argv[3] == "21"
    and proxy.argv[4] == proxy.source
    and proxy.argv[5] == "--listen-port"
    and proxy.argv[6] == tostring(proxy.port)
    and proxy.argv[7] == "--backend-port"
    and proxy.argv[8] == tostring(backend.port)
    and proxy.argv[9] == "--backend-pid"
    and proxy.argv[10] == tostring(backend.pid)
    and proxy.argv[11] == "--backend-start"
    and proxy.argv[12] == backend.start_time
    and proxy.argv[13] == "--boot-id"
    and proxy.argv[14] == state.boot_id
    and proxy.argv[15] == "--keystore"
    and proxy.argv[16] == paths().server_store
    and proxy.argv[17] == "--password-file"
    and proxy.argv[18] == paths().password
    and proxy.argv[19] == "--max-connections"
    and proxy.argv[20] == tostring(proxy_max_connections)
end

local function valid_broker_record(broker)
  return type(broker) == "table"
    and broker.protocol == 1
    and broker.control_path == paths().control
    and decimal_identity(broker.control_dev, true)
    and decimal_identity(broker.control_ino, false)
end

local function state_transport(state)
  if state and state.schema == 2 then
    return "tls-proxy"
  end
  return state and state.transport or nil
end

local function valid_pending(pending)
  if
    type(pending) ~= "table"
    or pending.hostname ~= hostname()
    or not valid_generation(pending.generation)
    or not valid_boot_id(pending.boot_id)
  then
    return false
  end
  if pending.schema == 4 then
    if
      pending.transport ~= "tls-proxy"
      or not valid_broker_record(pending.broker)
      or not valid_process_record(pending.proxy, "proxy")
    then
      return false
    end
    if pending.phase == "control-ready" then
      return pending.backend == nil
    end
    return pending.phase == "running"
      and valid_process_record(pending.backend, "backend")
      and valid_role_relationships(pending)
  end
  if not valid_process_record(pending.backend, "backend") then
    return false
  end
  if pending.schema == 2 then
    return (pending.proxy == nil or valid_process_record(pending.proxy, "proxy")) and valid_role_relationships(pending)
  end
  if pending.schema == 3 and (pending.transport == "tls-proxy" or pending.transport == "loopback-http") then
    if pending.transport == "tls-proxy" then
      return (pending.proxy == nil or valid_process_record(pending.proxy, "proxy"))
        and valid_role_relationships(pending)
    end
    return pending.proxy == nil
      and is_integer(pending.port, 1, 65535)
      and pending.backend.port == pending.port
      and valid_role_relationships(pending)
  end
  return false
end

local function valid_complete_state(state)
  if
    type(state) ~= "table"
    or (state.schema ~= 2 and state.schema ~= 3 and state.schema ~= 4)
    or state.hostname ~= hostname()
    or not valid_generation(state.generation)
    or state.host ~= host
    or not is_integer(state.port, 1, 65535)
    or not vim.tbl_contains({ "explicit", "persisted", "preferred 4096", "fallback" }, state.port_source)
    or type(state.started_at) ~= "string"
    or not absolute_path(state.cwd)
    or not valid_boot_id(state.boot_id)
    or not valid_process_record(state.backend, "backend")
  then
    return false
  end
  local transport = state_transport(state)
  if transport == "tls-proxy" then
    if
      state.url ~= ("https://%s:%d"):format(host, state.port)
      or state.ca_path ~= paths().ca
      or type(state.certificate_identity) ~= "string"
      or #state.certificate_identity ~= 64
      or not state.certificate_identity:match "^[0-9a-f]+$"
      or not valid_process_record(state.proxy, "proxy")
      or state.proxy.port ~= state.port
      or (state.schema == 4 and not valid_broker_record(state.broker))
      or (state.schema ~= 4 and state.broker ~= nil)
    then
      return false
    end
  elseif transport == "loopback-http" then
    if
      state.url ~= ("http://%s:%d"):format(host, state.port)
      or state.proxy ~= nil
      or state.ca_path ~= nil
      or state.certificate_identity ~= nil
      or state.backend.port ~= state.port
    then
      return false
    end
  else
    return false
  end
  local year, month, day, hour, minute, second =
    state.started_at:match "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
  if
    not year
    or tonumber(year) < 1970
    or tonumber(month) < 1
    or tonumber(month) > 12
    or tonumber(day) < 1
    or tonumber(day) > 31
    or tonumber(hour) > 23
    or tonumber(minute) > 59
    or tonumber(second) > 60
  then
    return false
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month == 2 and (year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)) then
    days_in_month[2] = 29
  end
  if day > days_in_month[month] then
    return false
  end
  return valid_role_relationships(state)
end

local function read_state()
  local state_path = paths().state
  local content = read_file(state_path)
  if not content then
    return nil, "missing"
  end
  local ok, state = pcall(vim.json.decode, content)
  if not ok or type(state) ~= "table" then
    return nil, "malformed"
  end
  if state.schema == 1 then
    if
      state.hostname ~= hostname()
      or type(state.pid) ~= "number"
      or state.pid <= 0
      or type(state.generation) ~= "string"
      or type(state.port) ~= "number"
      or type(state.url) ~= "string"
    then
      return nil, "malformed"
    end
    return state, "legacy"
  elseif type(state.schema) == "number" and state.schema % 1 == 0 and state.schema > 4 then
    return nil, "unsupported schema"
  elseif
    state.schema == 4
    and type(state.broker) == "table"
    and type(state.broker.protocol) == "number"
    and state.broker.protocol > 1
  then
    return nil, "unsupported broker protocol"
  elseif not valid_complete_state(state) then
    return nil, "malformed"
  end
  return state, "valid"
end

write_private = function(path, content, exclusive)
  local fd, err = uv.fs_open(path, exclusive and "wx" or "w", 384)
  if not fd then
    return nil, err
  end
  local ok, write_err = uv.fs_write(fd, content, 0)
  if ok then
    ok, write_err = uv.fs_fsync(fd)
  end
  uv.fs_close(fd)
  uv.fs_chmod(path, 384)
  if not ok then
    uv.fs_unlink(path)
    return nil, write_err
  end
  return true
end

local function write_state_under_fence(state)
  local fenced, fence_err = require_fence "lifecycle state publication"
  if not fenced then
    return nil, fence_err
  end
  local state_paths, err = ensure_state_dir()
  if not state_paths then
    return nil, err
  end
  local temporary = state_paths.state .. "." .. random_token() .. ".tmp"
  local ok, write_err = write_private(temporary, vim.json.encode(state))
  if not ok then
    return nil, "Unable to write OpenCode state: " .. (write_err or "unknown error")
  end
  local renamed, rename_err = uv.fs_rename(temporary, state_paths.state)
  if not renamed then
    uv.fs_unlink(temporary)
    return nil, "Unable to replace OpenCode state: " .. (rename_err or "unknown error")
  end
  uv.fs_chmod(state_paths.state, 384)
  return true
end

local function remove_matching_state_under_fence(generation)
  local fenced, fence_err = require_fence "lifecycle state removal"
  if not fenced then
    return nil, fence_err
  end
  local state = read_state()
  if state and state.generation == generation then
    run_test_hook "state_remove"
    local removed, remove_err = uv.fs_unlink(paths().state)
    if not removed then
      return nil, remove_err or "unable to remove matching lifecycle state"
    end
  end
  return true
end

local function curl_quote(value)
  return value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
end

local function curl_ca_config(state)
  if not state or state_transport(state) == "loopback-http" then
    return ""
  end
  if state_transport(state) ~= "tls-proxy" or type(state.ca_path) ~= "string" then
    return nil
  end
  return 'cacert = "' .. curl_quote(state.ca_path) .. '"\n'
end

local function probe_health(state, callback, authenticated)
  local ca_config = curl_ca_config(state)
  if not ca_config then
    callback(nil, { kind = "untrusted state", latency_ms = 0 })
    return
  end
  local started_at = uv.hrtime()
  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--connect-timeout",
    "1",
    "--max-time",
    "2",
    "--http1.1",
    "--config",
    "-",
    "--write-out",
    "\n%{http_code}",
    state.url .. "/global/health",
  }
  local config = ca_config .. 'header = "Accept: application/json"\n'
  if authenticated and vim.env.OPENCODE_SERVER_PASSWORD and vim.env.OPENCODE_SERVER_PASSWORD ~= "" then
    config = config
      .. 'user = "'
      .. curl_quote((vim.env.OPENCODE_SERVER_USERNAME or "opencode") .. ":" .. vim.env.OPENCODE_SERVER_PASSWORD)
      .. '"\n'
  end
  run_subprocess(command, { stdin = config, timeout_ms = 3000 }, function(result, subprocess_err)
    local response = result and result.stdout or ""
    local status = tonumber(response:match "\n(%d%d%d)%s*$")
    local body = response:gsub("\n%d%d%d%s*$", "")
    local latency_ms = math.floor((uv.hrtime() - started_at) / 1000000)
    if status == 401 then
      callback(nil, { kind = "unauthorized", latency_ms = latency_ms })
      return
    end
    if subprocess_err or not status or status < 200 or status >= 300 then
      local message = result and result.stderr or ""
      local kind = message:find("timed out", 1, true) and "timeout" or "unavailable"
      if result and result.timed_out then
        kind = "timeout"
      end
      callback(nil, {
        kind = kind,
        latency_ms = latency_ms,
        status = status,
        message = subprocess_err or vim.trim(message),
      })
      return
    end
    local ok, health = pcall(vim.json.decode, body)
    if not ok or type(health) ~= "table" then
      callback(nil, { kind = "invalid JSON", latency_ms = latency_ms })
      return
    end
    if health.healthy ~= true then
      callback(nil, { kind = "unhealthy", latency_ms = latency_ms })
      return
    end
    callback(health, { kind = "healthy", latency_ms = latency_ms, status = status })
  end)
end

-- Keep reload credentials and payloads on curl's stdin, as with health probes.
-- The directory header deliberately matches the attached TUI's current cwd.
local function request_json(state, path, method, body, directory, callback)
  local ca_config = curl_ca_config(state)
  if not ca_config then
    callback(nil, { kind = "untrusted state" })
    return
  end
  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--connect-timeout",
    "1",
    "--max-time",
    "4",
    "--http1.1",
    "--config",
    "-",
    "--write-out",
    "\n%{http_code}",
    "-X",
    method,
    state.url .. path,
  }
  local config = {
    'header = "Accept: application/json"',
    'header = "Content-Type: application/json"',
  }
  if directory and directory ~= "" then
    table.insert(config, 'header = "x-opencode-directory: ' .. curl_quote(directory) .. '"')
  end
  if vim.env.OPENCODE_SERVER_PASSWORD and vim.env.OPENCODE_SERVER_PASSWORD ~= "" then
    table.insert(
      config,
      'user = "'
        .. curl_quote((vim.env.OPENCODE_SERVER_USERNAME or "opencode") .. ":" .. vim.env.OPENCODE_SERVER_PASSWORD)
        .. '"'
    )
  end
  if body then
    table.insert(config, 'data-binary = "' .. curl_quote(vim.json.encode(body)) .. '"')
  end
  run_subprocess(
    command,
    { stdin = ca_config .. table.concat(config, "\n") .. "\n", timeout_ms = 5000 },
    function(result, subprocess_err)
      local response = result and result.stdout or ""
      local status = tonumber(response:match "\n(%d%d%d)%s*$")
      local response_body = response:gsub("\n%d%d%d%s*$", "")
      if status == 401 then
        callback(nil, { kind = "unauthorized", status = status })
      elseif subprocess_err or not status or status < 200 or status >= 300 then
        callback(nil, { kind = "HTTP " .. (status or "request failure"), status = status })
      elseif response_body == "" then
        callback({}, { kind = "ok", status = status })
      else
        local ok, decoded = pcall(vim.json.decode, response_body)
        callback(ok and decoded or nil, { kind = ok and "ok" or "invalid JSON", status = status })
      end
    end
  )
end

local function port_is_available(port)
  local tcp = uv.new_tcp()
  if not tcp then
    return false
  end
  local ok = tcp:bind(host, port)
  if ok == 0 then
    -- libuv can bind an already-listened-to port on some platforms until a
    -- listener is actually created. Probe the complete operation so automatic
    -- selection never mistakes an occupied endpoint for an available one.
    ok = tcp:listen(1, function() end)
  end
  tcp:close()
  return ok == 0
end

local function explicit_port()
  if server_config_error then
    return nil, "OpenCode server config " .. server_config_path .. " " .. server_config_error
  end
  local value = vim.env.OPENCODE_PORT
  if not value or value == "" then
    return nil
  end
  if not value:match "^%d+$" then
    return nil, "OPENCODE_PORT must be an integer from 1 through 65535"
  end
  local port = tonumber(value)
  if not port or port < 1 or port > 65535 then
    return nil, "OPENCODE_PORT must be an integer from 1 through 65535"
  end
  return port
end

local function pid_is_live(pid)
  if not uv.fs_stat("/proc/" .. pid) then
    return false
  end
  local stat = read_file("/proc/" .. pid .. "/stat")
  local state = stat and stat:match "%)%s+(%a)"
  return state ~= "Z"
end

local function proc_cmdline(pid)
  if vim.g.mkchad_opencode_test_api and vim.g.mkchad_opencode_test_procfs_authority == false then
    return nil
  end
  local command = read_file("/proc/" .. pid .. "/cmdline")
  if not command or command == "" then
    return nil
  end
  local argv = vim.split(command, "\0", { plain = true, trimempty = true })
  return #argv > 0 and argv or nil
end

local function proc_executable(pid)
  if vim.g.mkchad_opencode_test_api and vim.g.mkchad_opencode_test_procfs_authority == false then
    return nil
  end
  return uv.fs_readlink("/proc/" .. pid .. "/exe")
end

local function file_identity(path)
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local fdinfo = read_file("/proc/self/fdinfo/" .. fd)
  uv.fs_close(fd)
  local inode = fdinfo and fdinfo:match "\nino:%s*(%d+)%s*\n"
  if not inode then
    inode = fdinfo and fdinfo:match "^ino:%s*(%d+)%s*\n"
  end
  local device = stat and tostring(stat.dev)
  if not device or not decimal_identity(device, true) or not decimal_identity(inode, false) then
    return nil
  end
  return { dev = device, ino = inode }
end

local function proc_executable_identity(pid)
  return file_identity("/proc/" .. pid .. "/exe")
end

local function proc_start_time(pid)
  local stat = read_file("/proc/" .. pid .. "/stat")
  if not stat then
    return nil
  end
  local remainder = stat:match "^.*%)%s+(.+)$"
  local fields = remainder and vim.split(remainder, "%s+", { trimempty = true }) or nil
  return fields and fields[20] or nil
end

local function argv_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  for index, value in ipairs(left) do
    if value ~= right[index] then
      return false
    end
  end
  return true
end

local proc_line_limit = 4096
local proc_entry_limit = 200000
local proc_byte_limit = 16 * 1024 * 1024
local proc_scan_timeout_ns = 5 * 1000000000
local proc_headers = {
  tcp = {
    "sl",
    "local_address",
    "rem_address",
    "st",
    "tx_queue",
    "rx_queue",
    "tr",
    "tm->when",
    "retrnsmt",
    "uid",
    "timeout",
    "inode",
  },
  tcp6 = {
    "sl",
    "local_address",
    "remote_address",
    "st",
    "tx_queue",
    "rx_queue",
    "tr",
    "tm->when",
    "retrnsmt",
    "uid",
    "timeout",
    "inode",
  },
}
local proc_loopbacks = {
  tcp = { ["0100007F"] = true },
  tcp6 = {
    ["00000000000000000000000001000000"] = true,
    ["0000000000000000FFFF00000100007F"] = true,
  },
}

local function proc_fixed_hex(value, width)
  return type(value) == "string" and #value == width and value:match "^[%da-fA-F]+$" ~= nil
end

local function proc_unsigned_decimal(value, maximum)
  if
    type(value) ~= "string"
    or not value:match "^%d+$"
    or (#value > 1 and value:sub(1, 1) == "0")
    or #value > #maximum
  then
    return false
  end
  return #value < #maximum or value <= maximum
end

local function proc_hex_pair(value, left_width, right_width)
  return type(value) == "string"
    and #value == left_width + right_width + 1
    and value:sub(left_width + 1, left_width + 1) == ":"
    and proc_fixed_hex(value:sub(1, left_width), left_width)
    and proc_fixed_hex(value:sub(left_width + 2), right_width)
end

local function proc_endpoint(value, address_width)
  return proc_hex_pair(value, address_width, 4)
end

local function valid_proc_tcp_row(fields, family)
  local address_width = family == "tcp6" and 32 or 8
  local slot = fields[1] and fields[1]:match "^(%d+):$"
  if
    #fields < 4
    or not proc_unsigned_decimal(slot, "2147483647")
    or not proc_endpoint(fields[2], address_width)
    or not proc_endpoint(fields[3], address_width)
    or not proc_fixed_hex(fields[4], 2)
  then
    return false
  end
  local state = tonumber(fields[4], 16)
  local expected_fields = (state == 3 or state == 6) and 12 or 17
  if
    not state
    or state < 1
    or state > 13
    or #fields ~= expected_fields
    or not proc_hex_pair(fields[5], 8, 8)
    or not proc_hex_pair(fields[6], 2, 8)
    or tonumber(fields[6]:sub(1, 2), 16) > 4
    or not proc_fixed_hex(fields[7], 8)
    or not proc_unsigned_decimal(fields[8], "4294967295")
    or not proc_unsigned_decimal(fields[9], "2147483647")
    or not proc_unsigned_decimal(fields[10], "18446744073709551615")
    or not proc_unsigned_decimal(fields[11], "2147483647")
    or not (proc_fixed_hex(fields[12], 8) or proc_fixed_hex(fields[12], 16))
  then
    return false
  end
  return expected_fields == 12
    or (
      proc_unsigned_decimal(fields[13], "18446744073709551615")
      and proc_unsigned_decimal(fields[14], "18446744073709551615")
      and proc_unsigned_decimal(fields[15], "4294967295")
      and proc_unsigned_decimal(fields[16], "4294967295")
      and (fields[17] == "-1" or proc_unsigned_decimal(fields[17], "2147483647"))
    )
end

local function scan_proc_tcp_table(path, family, wanted_port, scan)
  local fd = uv.fs_open(path, "r", 0)
  if not fd then
    return false
  end
  local function scan_open_file()
    local offset, line_count = 0, 0
    local pending = ""
    while true do
      if uv.hrtime() > scan.deadline_ns then
        return false
      end
      local chunk = uv.fs_read(fd, 16 * 1024, offset)
      if chunk == nil then
        return false
      end
      if chunk == "" then
        break
      end
      offset = offset + #chunk
      scan.bytes = scan.bytes + #chunk
      if scan.bytes > proc_byte_limit then
        return false
      end
      pending = pending .. chunk
      while true do
        local newline = pending:find("\n", 1, true)
        if not newline then
          if #pending > proc_line_limit then
            return false
          end
          break
        end
        local line = pending:sub(1, newline - 1)
        pending = pending:sub(newline + 1)
        if #line > proc_line_limit or line:find "[%z\1-\31\127-\255]" or uv.hrtime() > scan.deadline_ns then
          return false
        end
        scan.entries = scan.entries + 1
        if scan.entries > proc_entry_limit then
          return false
        end
        local fields = vim.split(vim.trim(line), "%s+", { trimempty = true })
        if line_count == 0 then
          if not vim.deep_equal(fields, proc_headers[family]) then
            return false
          end
        else
          if not valid_proc_tcp_row(fields, family) then
            return false
          end
          local address, state, inode = fields[2], fields[4], fields[10]
          local ip, port = address:match "^([^:]+):([%da-fA-F]+)$"
          if state == "0A" and port:upper() == wanted_port and proc_loopbacks[family][ip:upper()] then
            scan.matches = scan.matches + 1
            scan.inode = inode
          end
        end
        line_count = line_count + 1
      end
    end
    return pending == "" and line_count > 0 and uv.hrtime() <= scan.deadline_ns
  end
  local ok, complete = pcall(scan_open_file)
  uv.fs_close(fd)
  return ok and complete or false
end

local function find_unique_listener_inode(port, table_paths)
  if not is_integer(port, 1, 65535) then
    return nil
  end
  table_paths = table_paths or { "/proc/net/tcp", "/proc/net/tcp6" }
  if type(table_paths) ~= "table" or #table_paths ~= 2 then
    return nil
  end
  local scan = {
    bytes = 0,
    entries = 0,
    matches = 0,
    deadline_ns = uv.hrtime() + proc_scan_timeout_ns,
  }
  local wanted_port = string.format("%04X", port)
  if
    not scan_proc_tcp_table(table_paths[1], "tcp", wanted_port, scan)
    or not scan_proc_tcp_table(table_paths[2], "tcp6", wanted_port, scan)
    or scan.matches ~= 1
  then
    return nil
  end
  return scan.inode
end

local function process_listens_on_port(pid, port)
  if vim.g.mkchad_opencode_test_api and vim.g.mkchad_opencode_test_procfs_authority == false then
    return false
  end
  local inode = find_unique_listener_inode(port)
  if not inode then
    return false
  end
  for _, fd in ipairs(vim.fn.glob("/proc/" .. pid .. "/fd/*", true, true)) do
    local owned_inode = (uv.fs_readlink(fd) or ""):match "^socket:%[(%d+)%]$"
    if owned_inode == inode then
      return true
    end
  end
  return false
end

local function process_identity_is_owned(process, boot_id)
  if not process or type(process.pid) ~= "number" or process.pid <= 0 then
    return false, "invalid managed PID"
  end
  if boot_id ~= current_boot_id() then
    return false, "host boot identity changed"
  end
  if not pid_is_live(process.pid) then
    return false, "PID is not live"
  end
  if not valid_process_record(process, process.source and "proxy" or "backend") then
    return false, "managed process identity is unavailable"
  end
  local executable = proc_executable_identity(process.pid)
  local argv = proc_cmdline(process.pid)
  if
    not executable
    or executable.dev ~= process.process_executable_dev
    or executable.ino ~= process.process_executable_ino
    or not argv_equal(argv, process.argv)
    or proc_start_time(process.pid) ~= process.start_time
  then
    return false, "PID executable inode, argv, or start identity does not match"
  end
  if
    process.executable_dev ~= process.process_executable_dev
    or process.executable_ino ~= process.process_executable_ino
  then
    local launch = file_identity(process.executable)
    if not launch or launch.dev ~= process.executable_dev or launch.ino ~= process.executable_ino then
      return false, "interpreted launch executable identity does not match"
    end
  end
  if process.source then
    local source = file_identity(process.source)
    if not source or source.dev ~= process.source_dev or source.ino ~= process.source_ino then
      return false, "Java proxy source identity does not match"
    end
  end
  return true, "verified"
end

local function legacy_process_is_owned(state)
  if not state or state.hostname ~= hostname() or type(state.pid) ~= "number" or state.pid <= 0 then
    return false, "invalid legacy PID"
  end
  if not pid_is_live(state.pid) then
    return false, "PID is not live"
  end
  return false,
    "schema 1 lacks boot ID, PID start time, and immutable executable identity; preserve state and use trusted OS process accounting to verify and terminate PID "
      .. state.pid
      .. " manually, then retry after it is dead"
end

local function process_is_owned(state)
  if state and state.schema == 1 then
    return legacy_process_is_owned(state)
  end
  if not state or state.hostname ~= hostname() then
    return false, "state hostname does not match"
  end
  local backend_ok, backend_reason = process_identity_is_owned(state.backend, state.boot_id)
  if not backend_ok then
    return false, "backend " .. backend_reason
  end
  if
    #state.backend.argv < 6
    or state.backend.argv[#state.backend.argv - 4] ~= "serve"
    or state.backend.argv[#state.backend.argv - 3] ~= "--hostname"
    or state.backend.argv[#state.backend.argv - 2] ~= host
    or state.backend.argv[#state.backend.argv - 1] ~= "--port"
    or state.backend.argv[#state.backend.argv] ~= tostring(state.backend.port)
  then
    return false, "backend argv is not an exact opencode serve command"
  end
  if state_transport(state) == "loopback-http" then
    if state.backend.port ~= state.port then
      return false, "direct backend public port does not match state"
    end
    return true, "verified"
  end
  local proxy_ok, proxy_reason = process_identity_is_owned(state.proxy, state.boot_id)
  if not proxy_ok then
    return false, "proxy " .. proxy_reason
  end
  if state.proxy.port ~= state.port then
    return false, "proxy public port does not match state"
  end
  if state.schema == 4 then
    return true, "verified"
  end
  if
    argv_option(state.proxy.argv, "--listen-port") ~= tostring(state.port)
    or argv_option(state.proxy.argv, "--backend-port") ~= tostring(state.backend.port)
    or argv_option(state.proxy.argv, "--backend-pid") ~= tostring(state.backend.pid)
    or argv_option(state.proxy.argv, "--backend-start") ~= state.backend.start_time
    or argv_option(state.proxy.argv, "--boot-id") ~= state.boot_id
    or argv_option(state.proxy.argv, "--keystore") ~= paths().server_store
    or argv_option(state.proxy.argv, "--password-file") ~= paths().password
  then
    return false, "proxy argv does not pin the recorded backend and certificate"
  end
  return true, "verified"
end

local renew_lock

local function signal_process(process, boot_id, requested_signal, deadline_ns, callback)
  local fenced, fence_err = require_fence "managed process signal"
  if not fenced then
    callback(false, fence_err)
    return
  end
  local renewed, lease_err = renew_lock()
  if not renewed then
    callback(
      false,
      "lifecycle lock ownership was lost before " .. requested_signal .. ": " .. (lease_err or "lease renewal failed")
    )
    return
  end
  local owned, reason = process_identity_is_owned(process, boot_id)
  if not owned then
    callback(false, reason)
    return
  end
  local signal_name = ({ sigterm = "SIGTERM", sigkill = "SIGKILL" })[requested_signal]
  local python = vim.fn.exepath "python3"
  local helper = paths().pidfd_helper
  if not signal_name or python == "" or not uv.fs_stat(helper) then
    callback(false, "Linux pidfd signal helper is unavailable")
    return
  end
  local request = {
    schema = 1,
    boot_id = boot_id,
    signal = signal_name,
    process = process,
  }
  local hook = vim.g.mkchad_opencode_test_api and test_hooks.signal or nil
  if hook then
    test_hooks.signal = nil
    request.test_pause = { marker = hook.marker, resume = hook.resume }
  end
  run_subprocess({ python, helper }, {
    stdin = vim.json.encode(request),
    timeout_ms = hook and 60000 or pidfd_helper_timeout_ms,
    deadline_ns = deadline_ns,
    env = hook and { MKCHAD_OPENCODE_PIDFD_TEST = "1" } or nil,
  }, function(result, subprocess_err)
    if not subprocess_err then
      callback(true)
      return
    end
    if result and result.timed_out then
      callback(false, "pidfd signal helper timed out")
      return
    end
    local detail = result and vim.trim(result.stderr) or ""
    callback(false, detail ~= "" and detail or subprocess_err or "pidfd signal helper refused the managed process")
  end)
end

local function terminate_process(process, boot_id, deadline_ns, callback)
  local owned, reason = process_identity_is_owned(process, boot_id)
  if not owned then
    callback(not process or not pid_is_live(process.pid), reason)
    return
  end
  signal_process(process, boot_id, "sigterm", deadline_ns, function(sent, signal_err)
    if not sent then
      callback(false, signal_err)
      return
    end
    local escalated = false
    local escalating = false
    local kill_at_ns = math.min(uv.hrtime() + subprocess_term_grace_ms * 1000000, deadline_ns)
    local function wait_for_exit()
      if not pid_is_live(process.pid) then
        callback(true)
        return
      end
      local now = uv.hrtime()
      if now >= kill_at_ns and not escalated then
        if not escalating then
          escalating = true
          signal_process(process, boot_id, "sigkill", deadline_ns, function(killed, kill_err)
            escalating = false
            if not killed then
              callback(not pid_is_live(process.pid), kill_err)
              return
            end
            escalated = true
            vim.defer_fn(wait_for_exit, health_interval_ms)
          end)
          return
        end
      elseif now >= deadline_ns and escalated then
        callback(false, "managed process did not exit after SIGKILL")
        return
      elseif now >= deadline_ns then
        callback(false, "managed process did not exit before the stop deadline")
        return
      end
      vim.defer_fn(wait_for_exit, health_interval_ms)
    end
    wait_for_exit()
  end)
end

local lock_claim
local lock_renew_timer

local function valid_lock_token(token)
  return type(token) == "string" and token ~= "" and token:match "^[%w_.%+-]+$" ~= nil
end

local function lock_lease_path(token, root)
  if not valid_lock_token(token) then
    return nil
  end
  return vim.fs.joinpath(root or paths().lock, "lease-" .. token .. ".json")
end

local function read_lock_owner()
  local owner_content = read_file(paths().lock_owner)
  if not owner_content then
    return nil
  end
  local ok, owner = pcall(vim.json.decode, owner_content)
  return ok and type(owner) == "table" and owner or nil
end

local function read_lock_lease(owner, root)
  local lease_path = owner and lock_lease_path(owner.token, root)
  local content = lease_path and read_file(lease_path)
  if not content then
    return nil
  end
  local ok, lease = pcall(vim.json.decode, content)
  return ok and type(lease) == "table" and lease or nil
end

local function owner_matches_claim(owner, lock_stat, claim)
  return owner
    and claim
    and owner.token == claim.token
    and owner.pid == vim.fn.getpid()
    and owner.hostname == hostname()
    and owner.boot_id == claim.boot_id
    and lock_stat
    and lock_stat.dev == claim.dev
    and lock_stat.ino == claim.ino
    and owner.lock_dev == claim.dev
    and owner.lock_ino == claim.ino
end

local function valid_lock_lease(lock_stat, owner, lease, now_ms)
  return lock_stat
    and owner
    and lease
    and valid_lock_token(owner.token)
    and owner.hostname == hostname()
    and owner.boot_id == current_boot_id()
    and owner.lock_dev == lock_stat.dev
    and owner.lock_ino == lock_stat.ino
    and lease.token == owner.token
    and lease.pid == owner.pid
    and lease.hostname == owner.hostname
    and lease.boot_id == owner.boot_id
    and lease.lock_dev == lock_stat.dev
    and lease.lock_ino == lock_stat.ino
    and type(lease.renewed_monotonic_ms) == "number"
    and type(lease.deadline_monotonic_ms) == "number"
    and lease.deadline_monotonic_ms >= lease.renewed_monotonic_ms
    and lease.deadline_monotonic_ms - lease.renewed_monotonic_ms <= startup_timeout_ms
    and lease.renewed_monotonic_ms <= now_ms
end

local function lock_is_owned()
  local owner = read_lock_owner()
  local lock_stat = uv.fs_stat(paths().lock)
  local lease = read_lock_lease(owner)
  local now_ms = monotonic_ms()
  return owner_matches_claim(owner, lock_stat, lock_claim)
    and valid_lock_lease(lock_stat, owner, lease, now_ms)
    and (fence_is_held() or lease.deadline_monotonic_ms > now_ms)
end

local function same_lock(stat, claim)
  return stat and claim and stat.dev == claim.dev and stat.ino == claim.ino
end

local function cleanup_created_lock(claim)
  if not fence_is_held() then
    return false
  end
  if not same_lock(uv.fs_stat(paths().lock), claim) then
    return false
  end
  local detached = paths().lock .. ".unpublished-" .. claim.token
  if not uv.fs_rename(paths().lock, detached) or not same_lock(uv.fs_stat(detached), claim) then
    return false
  end
  local content = read_file(vim.fs.joinpath(detached, "owner.json"))
  if content then
    local ok, owner = pcall(vim.json.decode, content)
    if not ok or not owner or owner.token ~= claim.token then
      uv.fs_rename(detached, paths().lock)
      return false
    end
    uv.fs_unlink(vim.fs.joinpath(detached, "owner.json"))
  end
  local lease_path = claim and lock_lease_path(claim.token, detached)
  if lease_path then
    uv.fs_unlink(lease_path)
  end
  return uv.fs_rmdir(detached) and true or false
end

local function stop_lock_renewal()
  if lock_renew_timer then
    lock_renew_timer:stop()
    lock_renew_timer:close()
    lock_renew_timer = nil
  end
end

renew_lock = function()
  local fenced, fence_err = require_fence "logical lock lease renewal"
  if not fenced then
    return nil, fence_err
  end
  local claim = lock_claim
  if not claim or not lock_is_owned() then
    return nil, "the current lease is absent, expired, or no longer owned"
  end
  local owner = read_lock_owner()
  local lock_stat = uv.fs_stat(paths().lock)
  if not owner_matches_claim(owner, lock_stat, claim) then
    return nil, "the startup lock directory or owner changed"
  end
  local now_ms = monotonic_ms()
  local lease = {
    token = claim.token,
    pid = vim.fn.getpid(),
    hostname = hostname(),
    boot_id = claim.boot_id,
    lock_dev = claim.dev,
    lock_ino = claim.ino,
    renewed_monotonic_ms = now_ms,
    deadline_monotonic_ms = now_ms + startup_timeout_ms,
  }
  local encoded = vim.json.encode(lease)
  local temporary = paths().root .. "/.lease-" .. random_token() .. ".tmp"
  local wrote, write_err = write_private(temporary, encoded, true)
  if not wrote then
    return nil, write_err or "unable to write renewed lease"
  end
  owner = read_lock_owner()
  lock_stat = uv.fs_stat(paths().lock)
  if not owner_matches_claim(owner, lock_stat, claim) or not lock_is_owned() then
    uv.fs_unlink(temporary)
    return nil, "the startup lock changed during lease renewal"
  end
  local lease_path = lock_lease_path(claim.token)
  local renamed, rename_err = uv.fs_rename(temporary, lease_path)
  if not renamed then
    uv.fs_unlink(temporary)
    return nil, rename_err or "unable to publish renewed lease"
  end
  local published = read_lock_lease(owner)
  lock_stat = uv.fs_stat(paths().lock)
  if
    not owner_matches_claim(read_lock_owner(), lock_stat, claim)
    or not valid_lock_lease(lock_stat, owner, published, monotonic_ms())
    or published.renewed_monotonic_ms ~= now_ms
  then
    return nil, "startup lock ownership changed while publishing the renewed lease"
  end
  return true
end

local function start_lock_renewal()
  stop_lock_renewal()
  lock_renew_timer = uv.new_timer()
  if not lock_renew_timer then
    return nil, "unable to create startup lock renewal timer"
  end
  lock_renew_timer:start(
    lock_renew_interval_ms,
    lock_renew_interval_ms,
    vim.schedule_wrap(function()
      local renewed = renew_lock()
      if not renewed then
        stop_lock_renewal()
      end
    end)
  )
  return true
end

local function require_lock_ownership(action)
  local fenced, fence_err = require_fence(action)
  if not fenced then
    return nil, fence_err
  end
  local renewed, err = renew_lock()
  if not renewed then
    return nil,
      "OpenCode lifecycle lock ownership was lost before " .. action .. ": " .. (err or "lease renewal failed")
  end
  return true
end

local function write_state_while_locked(state, action)
  local owned, ownership_err = require_lock_ownership(action or "lifecycle state update")
  if not owned then
    return nil, ownership_err
  end
  run_test_hook "state_publish"
  return write_state_under_fence(state)
end

local function remove_matching_state_while_locked(generation, action)
  local owned, ownership_err = require_lock_ownership(action or "lifecycle state removal")
  if not owned then
    return nil, ownership_err
  end
  return remove_matching_state_under_fence(generation)
end

local function remove_malformed_state_while_locked(action)
  local owned, ownership_err = require_lock_ownership(action or "malformed lifecycle state removal")
  if not owned then
    return nil, ownership_err
  end
  local state, status = read_state()
  if state or status ~= "malformed" then
    return nil, "lifecycle state changed before malformed-state removal"
  end
  run_test_hook "state_remove"
  local removed, remove_err = uv.fs_unlink(paths().state)
  if not removed then
    return nil, remove_err or "unable to remove malformed lifecycle state"
  end
  return true
end

release_lock = function()
  stop_lock_renewal()
  local claim = lock_claim
  if claim and lock_is_owned() then
    -- Atomically detach the exact lock directory we validated. This cannot
    -- unlink a newly acquired startup.lock after an expiry/reclaim race.
    local released = paths().lock .. ".release-" .. claim.token
    if uv.fs_rename(paths().lock, released) then
      local content = read_file(vim.fs.joinpath(released, "owner.json"))
      local ok, owner = false, nil
      if content then
        ok, owner = pcall(vim.json.decode, content)
      end
      local lease = read_lock_lease(owner, released)
      if
        same_lock(uv.fs_stat(released), claim)
        and ok
        and owner
        and owner.token == claim.token
        and owner.pid == vim.fn.getpid()
        and owner.hostname == hostname()
        and lease
        and lease.token == claim.token
      then
        uv.fs_unlink(lock_lease_path(claim.token, released))
        uv.fs_unlink(vim.fs.joinpath(released, "owner.json"))
        uv.fs_rmdir(released)
      else
        -- Preserve an unexpected owner record for diagnosis rather than
        -- removing it. A future bounded stale-lock reclaim can handle it.
        uv.fs_rename(released, paths().lock)
      end
    end
  end
  lock_claim = nil
  release_fence()
end

local function lock_is_stale(lock_stat, owner)
  lock_stat = lock_stat or uv.fs_stat(paths().lock)
  owner = owner or read_lock_owner()
  if not lock_stat then
    return false
  end
  local now_ms = realtime_ms()
  local modified_ms = lock_stat.mtime and lock_stat.mtime.sec * 1000 + math.floor((lock_stat.mtime.nsec or 0) / 1000000)
  local old_or_clock_invalid = modified_ms
    and (now_ms >= modified_ms + startup_timeout_ms or modified_ms > now_ms + startup_timeout_ms)
  -- A contender can observe the directory between mkdir and atomic owner
  -- publication. It is not stale merely because metadata is briefly absent.
  local lease = read_lock_lease(owner)
  local monotonic_now_ms = monotonic_ms()
  if
    not owner
    or owner.hostname ~= hostname()
    or type(owner.pid) ~= "number"
    or owner.pid <= 0
    or type(owner.token) ~= "string"
    or owner.token == ""
    or owner.lock_dev ~= lock_stat.dev
    or owner.lock_ino ~= lock_stat.ino
    or type(owner.acquired_at_unix_ms) ~= "number"
    or type(owner.boot_id) ~= "string"
    or owner.boot_id == ""
  then
    return old_or_clock_invalid or false
  end
  if owner.boot_id ~= current_boot_id() then
    return true
  end
  if not pid_is_live(owner.pid) then
    return true
  end
  if not valid_lock_lease(lock_stat, owner, lease, monotonic_now_ms) then
    return old_or_clock_invalid or false
  end
  return monotonic_now_ms >= lease.deadline_monotonic_ms
end

local function reclaim_stale_lock()
  if not fence_is_held() then
    return false
  end
  local lock_stat = uv.fs_stat(paths().lock)
  if not lock_stat then
    return false
  end
  local owner_content = read_file(paths().lock_owner)
  local owner = read_lock_owner()
  local lease_path = owner and lock_lease_path(owner.token)
  local lease_content = lease_path and read_file(lease_path) or nil
  if not lock_is_stale(lock_stat, owner) then
    return false
  end
  run_test_hook "logical_reclaim"
  -- Rename isolates exactly the directory that was checked. A new acquirer can
  -- create startup.lock after this rename without being removed by this cleanup.
  local tombstone = paths().lock .. ".stale-" .. random_token()
  if not uv.fs_rename(paths().lock, tombstone) then
    return false
  end
  if not same_lock(uv.fs_stat(tombstone), lock_stat) then
    uv.fs_rename(tombstone, paths().lock)
    return false
  end
  local moved_owner = read_file(vim.fs.joinpath(tombstone, "owner.json"))
  local moved_lease_path = owner and lock_lease_path(owner.token, tombstone)
  local moved_lease = moved_lease_path and read_file(moved_lease_path) or nil
  if moved_owner ~= owner_content or moved_lease ~= lease_content then
    -- Owner publication raced the stale check. Restore it and let the next
    -- bounded attempt validate the newly published owner.
    uv.fs_rename(tombstone, paths().lock)
    return false
  end
  if moved_lease_path then
    uv.fs_unlink(moved_lease_path)
  end
  uv.fs_unlink(vim.fs.joinpath(tombstone, "owner.json"))
  uv.fs_rmdir(tombstone)
  return true
end

local function publish_lock_owner(claim)
  local fenced, fence_err = require_fence "logical lock owner publication"
  if not fenced then
    return nil, fence_err
  end
  if not same_lock(uv.fs_stat(paths().lock), claim) then
    return nil, "startup lock directory changed before owner publication"
  end
  local acquired_at = realtime_ms()
  local acquired_monotonic_ms = monotonic_ms()
  local boot_id = current_boot_id()
  if not boot_id or boot_id == "" then
    return nil, "unable to read the host boot identity"
  end
  claim.boot_id = boot_id
  local owner = {
    token = claim.token,
    pid = vim.fn.getpid(),
    hostname = hostname(),
    lock_dev = claim.dev,
    lock_ino = claim.ino,
    boot_id = boot_id,
    acquired_at_unix_ms = acquired_at,
    acquired_monotonic_ms = acquired_monotonic_ms,
  }
  local lease = {
    token = claim.token,
    pid = vim.fn.getpid(),
    hostname = hostname(),
    boot_id = boot_id,
    lock_dev = claim.dev,
    lock_ino = claim.ino,
    renewed_monotonic_ms = acquired_monotonic_ms,
    deadline_monotonic_ms = acquired_monotonic_ms + startup_timeout_ms,
  }
  local lease_path = lock_lease_path(claim.token)
  local wrote_lease, lease_err = write_private(lease_path, vim.json.encode(lease), true)
  if not wrote_lease then
    return nil, lease_err
  end
  local wrote_owner, owner_err = write_private(paths().lock_owner, vim.json.encode(owner), true)
  if not wrote_owner then
    uv.fs_unlink(lease_path)
    return nil, owner_err
  end
  return true
end

local function acquire_logical_lock_under_fence(callback, retried)
  local state_paths, err = ensure_state_dir()
  if not state_paths then
    release_fence()
    callback(false, err)
    return
  end
  local token = random_token()
  if uv.fs_mkdir(state_paths.lock, 448) then
    local lock_stat = uv.fs_stat(state_paths.lock)
    local claim = lock_stat and { token = token, dev = lock_stat.dev, ino = lock_stat.ino } or nil
    lock_claim = claim
    local wrote, write_err
    if claim then
      wrote, write_err = publish_lock_owner(claim)
    else
      write_err = "unable to stat the newly created startup lock"
    end
    if not wrote then
      cleanup_created_lock(claim)
      lock_claim = nil
      release_fence()
      callback(false, "Unable to write OpenCode startup lock: " .. (write_err or "unknown error"))
      return
    end
    if not require_lock_ownership "startup critical section" then
      release_lock()
      callback(false, "OpenCode startup lock ownership was lost before startup")
      return
    end
    local renewing, renewal_err = start_lock_renewal()
    if not renewing then
      release_lock()
      callback(false, "Unable to renew OpenCode startup lock: " .. renewal_err)
      return
    end
    callback(true)
    return
  end
  if not retried and reclaim_stale_lock() then
    acquire_logical_lock_under_fence(callback, true)
    return
  end
  release_fence()
  callback(false, "OpenCode startup is already in progress")
end

local function acquire_lock(callback, retried, deadline_ns)
  local operation_deadline = deadline_ns or (uv.hrtime() + startup_timeout_ms * 1000000)
  local fence_deadline = math.min(operation_deadline, uv.hrtime() + fence_acquire_timeout_ms * 1000000)
  acquire_fence(function(acquired, fence_err)
    if not acquired then
      callback(false, fence_err)
      return
    end
    local ok, acquire_err = xpcall(function()
      acquire_logical_lock_under_fence(callback, retried)
    end, debug.traceback)
    if not ok then
      release_lock()
      error(acquire_err, 0)
    end
  end, fence_deadline)
end

local function resolve_executable(deadline_ns, callback)
  local discovered = vim.fn.exepath "opencode"
  if discovered == "" then
    callback(nil, nil, "Unable to find opencode on PATH")
    return
  end
  local executable = uv.fs_realpath(discovered)
  if not executable then
    callback(nil, nil, "Unable to resolve the canonical opencode executable")
    return
  end
  run_subprocess({ executable, "--version" }, { deadline_ns = deadline_ns }, function(result, subprocess_err)
    if subprocess_err then
      callback(nil, nil, "Unable to query the bounded OpenCode version: " .. subprocess_err)
      return
    end
    local version = result.stdout:match "^([^\r\n]+)"
    if not safe_string(version, 128) then
      callback(nil, nil, "OpenCode version output was malformed")
      return
    end
    callback(executable, version)
  end)
end

local function select_port(state, excluded_ports)
  local function available(port)
    return not (excluded_ports and excluded_ports[port]) and port_is_available(port)
  end
  local requested, request_err = explicit_port()
  if request_err then
    return nil, nil, request_err
  end
  if requested then
    if not port_is_available(requested) then
      local label = server_setting_source "OPENCODE_PORT" == "config file" and "Configured OpenCode port "
        or "Explicit OPENCODE_PORT "
      return nil, nil, label .. requested .. " is occupied by an unknown or incompatible service"
    end
    return requested, "explicit"
  end
  if state and available(state.port) then
    return state.port, "persisted"
  end
  if available(preferred_port) then
    return preferred_port, "preferred 4096"
  end
  for _ = 1, 20 do
    local bytes = uv.random(2)
    local candidate = bytes and #bytes == 2 and 49152 + ((bytes:byte(1) * 256 + bytes:byte(2)) % 16384)
      or math.random(49152, 65535)
    if available(candidate) then
      return candidate, "fallback"
    end
  end
  return nil, nil, "Unable to find an available OpenCode port"
end

local function remove_known_directory(directory, names)
  for _, name in ipairs(names) do
    uv.fs_unlink(vim.fs.joinpath(directory, name))
  end
  uv.fs_rmdir(directory)
end

local function run_keytool(arguments, deadline_ns, callback)
  local keytool = vim.fn.exepath "keytool"
  if keytool == "" then
    callback(nil, "keytool is unavailable")
    return
  end
  local command = { keytool }
  vim.list_extend(command, arguments)
  run_subprocess(command, { deadline_ns = deadline_ns }, function(result, subprocess_err)
    callback(not subprocess_err and result or nil, subprocess_err)
  end)
end

local function certificate_identity(state_paths)
  local ca = read_file(state_paths.ca)
  local store = read_file(state_paths.server_store)
  return ca and store and vim.fn.sha256(ca .. store) or nil
end

local function validate_certificate_material(state_paths, deadline_ns, callback)
  for _, path in ipairs {
    state_paths.password,
    state_paths.ca,
    state_paths.ca_store,
    state_paths.server_store,
    state_paths.server_cert,
  } do
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      callback(nil, "certificate material is incomplete")
      return
    end
    uv.fs_chmod(path, 384)
  end
  uv.fs_chmod(state_paths.tls, 448)
  run_keytool(
    {
      "-list",
      "-alias",
      "mkchad-ca",
      "-keystore",
      state_paths.ca_store,
      "-storetype",
      "PKCS12",
      "-storepass:file",
      state_paths.password,
    },
    deadline_ns,
    function(ca_result, ca_err)
      if not ca_result then
        callback(nil, "CA keystore validation failed: " .. (ca_err or "unknown error"))
        return
      end
      run_keytool(
        {
          "-list",
          "-alias",
          "server",
          "-keystore",
          state_paths.server_store,
          "-storetype",
          "PKCS12",
          "-storepass:file",
          state_paths.password,
        },
        deadline_ns,
        function(server_result, server_err)
          if not server_result then
            callback(nil, "server keystore validation failed: " .. (server_err or "unknown error"))
            return
          end
          local java = vim.fn.exepath "java"
          if java == "" or not uv.fs_stat(state_paths.proxy_source) then
            callback(nil, "Java keystore validator is unavailable")
            return
          end
          run_subprocess({
            java,
            "--source",
            "21",
            state_paths.proxy_source,
            "--validate-keystore",
            state_paths.server_store,
            "--password-file",
            state_paths.password,
            "--ca-file",
            state_paths.ca,
            "--ca-keystore",
            state_paths.ca_store,
          }, { deadline_ns = deadline_ns }, function(_, java_err)
            local identity = not java_err and certificate_identity(state_paths) or nil
            if not identity then
              callback(nil, "certificate keystore validation failed: " .. (java_err or "identity unavailable"))
              return
            end
            callback(identity)
          end)
        end
      )
    end
  )
end

local function generate_certificate_material(state_paths, deadline_ns, callback)
  local staging = state_paths.tls .. ".new-" .. random_token()
  if not uv.fs_mkdir(staging, 448) then
    callback(nil, "unable to create certificate staging directory")
    return
  end
  local files = {
    password = vim.fs.joinpath(staging, "store.password"),
    ca = vim.fs.joinpath(staging, "ca.pem"),
    ca_store = vim.fs.joinpath(staging, "ca.p12"),
    server_store = vim.fs.joinpath(staging, "server.p12"),
    server_cert = vim.fs.joinpath(staging, "server.pem"),
    request = vim.fs.joinpath(staging, "server.csr"),
  }
  local random = uv.random(32) or random_token()
  local wrote, write_err = write_private(files.password, vim.fn.sha256(random .. random_token()), true)
  if not wrote then
    remove_known_directory(staging, { "store.password" })
    callback(nil, "unable to create certificate password file: " .. (write_err or "unknown error"))
    return
  end
  local commands = {
    {
      "-genkeypair",
      "-alias",
      "mkchad-ca",
      "-keyalg",
      "EC",
      "-groupname",
      "secp256r1",
      "-dname",
      "CN=MkChad OpenCode " .. hostname() .. " CA",
      "-ext",
      "bc:c",
      "-ext",
      "ku=keyCertSign,cRLSign",
      "-validity",
      "3650",
      "-keystore",
      files.ca_store,
      "-storetype",
      "PKCS12",
      "-storepass:file",
      files.password,
      "-noprompt",
    },
    {
      "-exportcert",
      "-rfc",
      "-alias",
      "mkchad-ca",
      "-keystore",
      files.ca_store,
      "-storepass:file",
      files.password,
      "-file",
      files.ca,
    },
    {
      "-genkeypair",
      "-alias",
      "server",
      "-keyalg",
      "EC",
      "-groupname",
      "secp256r1",
      "-dname",
      "CN=127.0.0.1",
      "-ext",
      "SAN=IP:127.0.0.1",
      "-validity",
      "825",
      "-keystore",
      files.server_store,
      "-storetype",
      "PKCS12",
      "-storepass:file",
      files.password,
      "-noprompt",
    },
    {
      "-certreq",
      "-alias",
      "server",
      "-keystore",
      files.server_store,
      "-storepass:file",
      files.password,
      "-file",
      files.request,
    },
    {
      "-gencert",
      "-rfc",
      "-alias",
      "mkchad-ca",
      "-keystore",
      files.ca_store,
      "-storepass:file",
      files.password,
      "-infile",
      files.request,
      "-outfile",
      files.server_cert,
      "-validity",
      "825",
      "-ext",
      "SAN=IP:127.0.0.1",
      "-ext",
      "KU=digitalSignature,keyEncipherment",
      "-ext",
      "EKU=serverAuth",
    },
    {
      "-importcert",
      "-alias",
      "mkchad-ca",
      "-keystore",
      files.server_store,
      "-storepass:file",
      files.password,
      "-file",
      files.ca,
      "-noprompt",
    },
    {
      "-importcert",
      "-alias",
      "server",
      "-keystore",
      files.server_store,
      "-storepass:file",
      files.password,
      "-file",
      files.server_cert,
      "-noprompt",
    },
  }
  local function fail(message)
    remove_known_directory(staging, { "store.password", "ca.pem", "ca.p12", "server.p12", "server.pem", "server.csr" })
    callback(nil, message)
  end
  local function publish(identity)
    local previous
    if uv.fs_stat(state_paths.tls) then
      previous = state_paths.tls .. ".invalid-" .. random_token()
      if not uv.fs_rename(state_paths.tls, previous) then
        fail "unable to isolate invalid certificate material"
        return
      end
    end
    if not uv.fs_rename(staging, state_paths.tls) then
      if previous then
        uv.fs_rename(previous, state_paths.tls)
      end
      remove_known_directory(
        staging,
        { "store.password", "ca.pem", "ca.p12", "server.p12", "server.pem", "server.csr" }
      )
      callback(nil, "unable to publish generated certificate material")
      return
    end
    if previous then
      remove_known_directory(
        previous,
        { "store.password", "ca.pem", "ca.p12", "server.p12", "server.pem", "server.csr" }
      )
    end
    callback(identity)
  end
  local function run_command(index)
    if index > #commands then
      uv.fs_unlink(files.request)
      for _, path in pairs(files) do
        if path ~= files.request then
          uv.fs_chmod(path, 384)
        end
      end
      local staged_paths = vim.tbl_extend("force", state_paths, {
        tls = staging,
        password = files.password,
        ca = files.ca,
        ca_store = files.ca_store,
        server_store = files.server_store,
        server_cert = files.server_cert,
      })
      validate_certificate_material(staged_paths, deadline_ns, function(identity, validation_err)
        if not identity then
          fail("generated certificate validation failed: " .. (validation_err or "unknown error"))
          return
        end
        publish(identity)
      end)
      return
    end
    run_keytool(commands[index], deadline_ns, function(result, command_err)
      if not result then
        fail("keytool certificate generation failed: " .. (command_err or "unknown error"))
        return
      end
      run_command(index + 1)
    end)
  end
  run_command(1)
end

local function ensure_certificate_material(deadline_ns, callback)
  if type(deadline_ns) == "function" then
    callback = deadline_ns
    deadline_ns = nil
  end
  deadline_ns = deadline_ns or (uv.hrtime() + startup_timeout_ms * 1000000)
  local fenced, fence_err = require_fence "certificate material validation or publication"
  if not fenced then
    callback(nil, fence_err)
    return
  end
  local state_paths, state_err = ensure_state_dir()
  if not state_paths then
    callback(nil, state_err)
    return
  end
  validate_certificate_material(state_paths, deadline_ns, function(identity, validation_err)
    if identity then
      callback(identity)
      return
    end
    generate_certificate_material(state_paths, deadline_ns, function(generated, generation_err)
      if not generated then
        callback(nil, generation_err .. " (existing material: " .. validation_err .. ")")
        return
      end
      callback(generated)
    end)
  end)
end

local function select_internal_port(public_port, excluded)
  for _ = 1, 40 do
    local bytes = uv.random(2)
    local candidate = bytes and #bytes == 2 and 49152 + ((bytes:byte(1) * 256 + bytes:byte(2)) % 16384)
      or math.random(49152, 65535)
    if candidate ~= public_port and not (excluded and excluded[candidate]) and port_is_available(candidate) then
      return candidate
    end
  end
  return nil, "Unable to find an available internal OpenCode port"
end

local function open_process_stdio(log_path)
  local root, root_err = ensure_state_dir()
  if not root then
    return nil, nil, root_err
  end
  local existing = uv.fs_lstat(log_path)
  if existing and (existing.type ~= "file" or existing.uid ~= uv.getuid() or existing.mode % 512 ~= 384) then
    return nil, nil, "process log path is unsafe"
  end
  if not existing then
    local created, create_err = write_private(log_path, "", true)
    if not created then
      return nil, nil, create_err or "unable to create private process log"
    end
  end
  if not authority_root_is_stable(root.root_identity) then
    return nil, nil, "OpenCode authority root changed before process log open"
  end
  local log_fd, log_err = uv.fs_open(log_path, "a", 384)
  local stdin_fd = uv.fs_open("/dev/null", "r", 0)
  if not log_fd or not stdin_fd then
    if log_fd then
      uv.fs_close(log_fd)
    end
    if stdin_fd then
      uv.fs_close(stdin_fd)
    end
    return nil, nil, log_err or "unable to open process stdio"
  end
  uv.fs_chmod(log_path, 384)
  return stdin_fd, log_fd
end

local function spawn_detached(executable, arguments, log_path)
  local stdin_fd, log_fd, io_err = open_process_stdio(log_path)
  if not stdin_fd then
    return nil, io_err
  end
  local handle, pid = uv.spawn(executable, {
    args = arguments,
    cwd = paths().root,
    detached = true,
    stdio = { stdin_fd, log_fd, log_fd },
  }, function() end)
  uv.fs_close(stdin_fd)
  uv.fs_close(log_fd)
  if not handle or not pid then
    return nil, "unable to launch detached process"
  end
  handle:unref()
  handle:close()
  return pid
end

local function capture_process(pid, extra)
  local executable_identity = proc_executable_identity(pid)
  local process = vim.tbl_extend("force", extra or {}, {
    pid = pid,
    process_executable = proc_executable(pid),
    process_executable_dev = executable_identity and executable_identity.dev,
    process_executable_ino = executable_identity and executable_identity.ino,
    argv = proc_cmdline(pid),
    start_time = proc_start_time(pid),
  })
  if not process.process_executable or not executable_identity or not process.argv or not process.start_time then
    return nil, "child exited before its identity could be recorded"
  end
  return process
end

function test_hooks.uint64_decimal(value)
  return tostring(value):match "^(%d+)ULL$"
end

function test_hooks.statx_function()
  if not ffi_ok then
    return nil
  end
  local resolved, symbol = pcall(function()
    return ffi.C.dlsym(nil, "statx")
  end)
  if not resolved or symbol == nil then
    return nil
  end
  local cast, statx = pcall(ffi.cast, "mkchad_statx_fn", symbol)
  return cast and statx or nil
end

function test_hooks.exact_lstat_inode(path)
  if not ffi_ok or not absolute_path(path) then
    return nil
  end
  local statx = test_hooks.statx_function()
  if not statx then
    return nil
  end
  local buffer = ffi.new "struct mkchad_statx[1]"
  local called, result = pcall(function()
    return statx(-100, path, 0x100, 0x100, buffer)
  end)
  local mask = called and tonumber(buffer[0].stx_mask) or 0
  if not called or result ~= 0 or math.floor(mask / 0x100) % 2 ~= 1 then
    return nil
  end
  local inode = test_hooks.uint64_decimal(buffer[0].stx_ino)
  return inode and inode ~= "0" and inode or nil
end

local function private_socket_identity(path, root_identity)
  if root_identity and not authority_root_is_stable(root_identity) then
    return nil
  end
  local entry = uv.fs_lstat(path)
  if not entry or entry.type ~= "socket" or entry.mode % 512 ~= 384 or (uv.getuid and entry.uid ~= uv.getuid()) then
    return nil
  end
  local inode = test_hooks.exact_lstat_inode(path)
  return inode and { dev = tostring(entry.dev), ino = inode } or nil
end

function test_hooks.reclaim_dead_schema4_control_while_locked(state)
  local owned, ownership_err = require_lock_ownership "schema-4 stale control reconciliation"
  if not owned then
    return nil, ownership_err
  end
  if pid_is_live(state.proxy.pid) or (state.backend and pid_is_live(state.backend.pid)) then
    return nil, "schema-4 control may still belong to a live role"
  end
  local root_identity, root_err = test_hooks.read_authority_root()
  if not root_identity then
    return nil, root_err
  end
  local entry = uv.fs_lstat(state.broker.control_path)
  if not entry then
    return true
  end
  if entry.type ~= "socket" or entry.mode % 512 ~= 384 or (uv.getuid and entry.uid ~= uv.getuid()) then
    return nil, "schema-4 stale control path is unsafe or not a socket"
  end
  local inode = test_hooks.exact_lstat_inode(state.broker.control_path)
  if tostring(entry.dev) ~= state.broker.control_dev or inode ~= state.broker.control_ino then
    return nil, "schema-4 stale control inode differs from the recorded generation"
  end
  local quarantine = paths().control_quarantine
  if uv.fs_lstat(quarantine) then
    return nil, "schema-4 stale control quarantine requires manual inspection"
  end
  if not uv.fs_rename(state.broker.control_path, quarantine) then
    return nil, "unable to quarantine the matching dead schema-4 control socket"
  end
  local moved = uv.fs_lstat(quarantine)
  local moved_inode = test_hooks.exact_lstat_inode(quarantine)
  if
    not moved
    or moved.type ~= "socket"
    or tostring(moved.dev) ~= state.broker.control_dev
    or moved_inode ~= state.broker.control_ino
    or not authority_root_is_stable(root_identity)
  then
    return nil, "schema-4 control changed while being quarantined"
  end
  if not uv.fs_unlink(quarantine) then
    return nil, "unable to remove the quarantined dead schema-4 control socket"
  end
  return true
end

local function strict_json_objects(value)
  local index, length = 1, #value
  local function whitespace()
    while index <= length and value:sub(index, index):match "%s" do
      index = index + 1
    end
  end
  local function string_value()
    if value:sub(index, index) ~= '"' then
      return false
    end
    index = index + 1
    while index <= length do
      local byte = value:byte(index)
      if byte == 34 then
        index = index + 1
        return true
      end
      if byte < 32 then
        return false
      end
      if byte == 92 then
        local escape = value:sub(index + 1, index + 1)
        if escape:match '["\\/bfnrt]' then
          index = index + 2
        elseif escape == "u" and value:sub(index + 2, index + 5):match "^[%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F]$" then
          index = index + 6
        else
          return false
        end
      else
        index = index + 1
      end
    end
    return false
  end
  local value_at
  local function object()
    if value:sub(index, index) ~= "{" then
      return false
    end
    index = index + 1
    whitespace()
    local seen = {}
    if value:sub(index, index) == "}" then
      index = index + 1
      return true
    end
    while true do
      local start = index
      if not string_value() then
        return false
      end
      local key = value:sub(start + 1, index - 2)
      if key:find("\\", 1, true) or seen[key] then
        return false
      end
      seen[key] = true
      whitespace()
      if value:sub(index, index) ~= ":" then
        return false
      end
      index = index + 1
      whitespace()
      if not value_at() then
        return false
      end
      whitespace()
      local delimiter = value:sub(index, index)
      if delimiter == "}" then
        index = index + 1
        return true
      end
      if delimiter ~= "," then
        return false
      end
      index = index + 1
      whitespace()
    end
  end
  local function array()
    if value:sub(index, index) ~= "[" then
      return false
    end
    index = index + 1
    whitespace()
    if value:sub(index, index) == "]" then
      index = index + 1
      return true
    end
    while true do
      if not value_at() then
        return false
      end
      whitespace()
      local delimiter = value:sub(index, index)
      if delimiter == "]" then
        index = index + 1
        return true
      end
      if delimiter ~= "," then
        return false
      end
      index = index + 1
      whitespace()
    end
  end
  value_at = function()
    whitespace()
    local first = value:sub(index, index)
    if first == "{" then
      return object()
    end
    if first == "[" then
      return array()
    end
    if first == '"' then
      return string_value()
    end
    local remainder = value:sub(index)
    local token = remainder:match "^[%d%.eE+-]+" or remainder:match "^[a-z]+"
    if not token or (token ~= "true" and token ~= "false" and token ~= "null" and not token:match "^[%d%.eE+-]+$") then
      return false
    end
    index = index + #token
    return true
  end
  whitespace()
  return value_at() and (whitespace() or true) and index == length + 1
end

local function exact_fields(value, required, optional)
  if type(value) ~= "table" or vim.islist(value) then
    return false
  end
  for key in pairs(value) do
    if not required[key] and not (optional and optional[key]) then
      return false
    end
  end
  for key in pairs(required) do
    if value[key] == nil then
      return false
    end
  end
  return true
end

local function valid_broker_response(response, operation, generation, nonce, control, socket)
  local required = {
    protocol = true,
    operation = true,
    generation = true,
    nonce = true,
    phase = true,
    control = true,
    proxy = true,
  }
  local phase = response and response.phase
  local optional = phase == "running" and { backend = true }
    or (phase == "activation-failed" or phase == "unhealthy" or phase == "blocked") and { error = true }
    or (phase == "activating" or phase == "control-ready" or phase == "stopping" or phase == "stopped") and {}
    or nil
  if
    not optional
    or not exact_fields(response, required, optional)
    or response.protocol ~= 1
    or response.operation ~= operation
    or response.generation ~= generation
    or response.nonce ~= nonce
    or not exact_fields(response.control, { path = true, dev = true, ino = true })
    or response.control.path ~= control
    or response.control.dev ~= socket.dev
    or response.control.ino ~= socket.ino
    or not exact_fields(response.proxy, {
      pid = true,
      port = true,
      argv = true,
      process_executable = true,
      process_executable_dev = true,
      process_executable_ino = true,
      executable = true,
      executable_dev = true,
      executable_ino = true,
      start_time = true,
      source = true,
      source_dev = true,
      source_ino = true,
    })
  then
    return false
  end
  local proxy = vim.tbl_extend("force", vim.deepcopy(response.proxy), { log = paths().proxy_log })
  if not valid_process_record(proxy, "proxy") then
    return false
  end
  if phase == "running" then
    return exact_fields(response.backend, {
      pid = true,
      port = true,
      argv = true,
      process_executable = true,
      process_executable_dev = true,
      process_executable_ino = true,
      executable = true,
      executable_dev = true,
      executable_ino = true,
      start_time = true,
      local_version = true,
      log = true,
    }, { server_version = true }) and valid_process_record(response.backend, "backend")
  end
  return phase ~= "activation-failed" and phase ~= "unhealthy" and phase ~= "blocked"
    or (type(response.error) == "string" and response.error:match "^[a-z-]+$" ~= nil)
end

local function broker_exchange(control, operation, generation, root_identity, expected_socket, callback)
  local socket = private_socket_identity(control, root_identity)
  if expected_socket and socket and (socket.dev ~= expected_socket.dev or socket.ino ~= expected_socket.ino) then
    socket = nil
  end
  if not socket then
    callback(nil, "broker control socket identity is unavailable")
    return
  end
  local pipe = uv.new_pipe(false)
  local timer = uv.new_timer()
  local done, chunks, received = false, {}, 0
  local nonce = random_token()
  local function finish(response, err)
    if done then
      return
    end
    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if pipe and not pipe:is_closing() then
      pipe:close()
    end
    vim.schedule(function()
      callback(response, err)
    end)
  end
  if not pipe or not timer then
    finish(nil, "broker control channel is unavailable")
    return
  end
  timer:start(3000, 0, function()
    finish(nil, "broker control exchange timed out")
  end)
  pipe:connect(control, function(err)
    if err then
      return finish(nil, "broker control connection failed")
    end
    pipe:read_start(function(read_err, chunk)
      if read_err then
        return finish(nil, "broker control read failed")
      end
      if chunk then
        received = received + #chunk
        if received > 65540 then
          return finish(nil, "broker control response exceeds its bound")
        end
        table.insert(chunks, chunk)
        return
      end
      local frame = table.concat(chunks)
      if #frame < 4 then
        return finish(nil, "broker control response is incomplete")
      end
      local size = frame:byte(1) * 16777216 + frame:byte(2) * 65536 + frame:byte(3) * 256 + frame:byte(4)
      if size < 2 or size > 65536 or #frame ~= size + 4 then
        return finish(nil, "broker control response framing is invalid")
      end
      local body = frame:sub(5)
      local strict = strict_json_objects(body)
      local ok, response = false, nil
      if strict then
        ok, response = pcall(vim.json.decode, body)
      end
      if not strict or not ok then
        return finish(nil, "broker control response JSON is malformed")
      end
      local final_socket = private_socket_identity(control, root_identity)
      if
        not authority_root_is_stable(root_identity)
        or (response.phase == "stopped" and operation == "stop" and final_socket ~= nil)
        or (
          response.phase ~= "stopped"
          and (not final_socket or final_socket.dev ~= socket.dev or final_socket.ino ~= socket.ino)
        )
      then
        return finish(nil, "broker control authority path changed during exchange")
      end
      if response.protocol ~= 1 then
        return finish(nil, "broker control protocol is unsupported future authority")
      end
      if not valid_broker_response(response, operation, generation, nonce, control, socket) then
        return finish(nil, "broker control response does not match the recorded authority")
      end
      finish(response)
    end)
    local body = vim.json.encode { protocol = 1, operation = operation, generation = generation, nonce = nonce }
    if #body > 65536 then
      return finish(nil, "broker control request is oversized")
    end
    local size = #body
    local frame = string.char(
      math.floor(size / 16777216) % 256,
      math.floor(size / 65536) % 256,
      math.floor(size / 256) % 256,
      size % 256
    ) .. body
    pipe:write(frame, function(write_err)
      if write_err then
        return finish(nil, "broker control write failed")
      end
      pipe:shutdown(function(shutdown_err)
        if shutdown_err then
          finish(nil, "broker control half-close failed")
        end
      end)
    end)
  end)
end

local function write_pending(pending)
  if not valid_pending(pending) then
    return nil, "refusing to write malformed pending startup metadata"
  end
  local owned, ownership_err = require_lock_ownership("pending generation " .. pending.generation .. " write")
  if not owned then
    return nil, ownership_err
  end
  if vim.g.mkchad_opencode_test_api and vim.g.mkchad_opencode_test_fail_pending_write then
    return nil, "injected pending write failure"
  end
  if vim.g.mkchad_opencode_test_api and is_integer(vim.g.mkchad_opencode_test_fail_pending_write_after, 1, 100) then
    if vim.g.mkchad_opencode_test_fail_pending_write_after == 1 then
      return nil, "injected pending write failure"
    end
    vim.g.mkchad_opencode_test_fail_pending_write_after = vim.g.mkchad_opencode_test_fail_pending_write_after - 1
  end
  local temporary = paths().pending .. "." .. random_token() .. ".tmp"
  local wrote, write_err = write_private(temporary, vim.json.encode(pending), true)
  if not wrote then
    return nil, write_err
  end
  owned, ownership_err = require_lock_ownership("pending generation " .. pending.generation .. " publication")
  if not owned then
    uv.fs_unlink(temporary)
    return nil, ownership_err
  end
  run_test_hook "pending_write"
  local renamed, rename_err = uv.fs_rename(temporary, paths().pending)
  if not renamed then
    uv.fs_unlink(temporary)
    return nil, rename_err
  end
  return true
end

local function has_only_fields(value, fields)
  if type(value) ~= "table" or vim.islist(value) then
    return false
  end
  for key in pairs(value) do
    if not fields[key] then
      return false
    end
  end
  for key in pairs(fields) do
    if value[key] == nil and fields[key] ~= "optional" then
      return false
    end
  end
  return true
end

local function valid_broker_launch_intent(intent)
  if
    type(intent) ~= "table"
    or intent.schema ~= 2
    or intent.transport ~= "tls-proxy"
    or intent.hostname ~= hostname()
    or not valid_generation(intent.generation)
    or not valid_boot_id(intent.boot_id)
    or not has_only_fields(intent, {
      schema = true,
      transport = true,
      hostname = true,
      generation = true,
      boot_id = true,
      proxy = true,
      public = true,
      control = true,
      backend = true,
    })
    or not has_only_fields(intent.public, { role = true, port = true })
    or intent.public.role ~= "public"
    or not is_integer(intent.public.port, 1, 65535)
    or not has_only_fields(intent.control, { protocol = true, path = true })
    or intent.control.protocol ~= 1
    or intent.control.path ~= paths().control
    or not has_only_fields(intent.backend, {
      role = true,
      executable = true,
      executable_dev = true,
      executable_ino = true,
      version = true,
      port = true,
      log = true,
    })
    or intent.backend.role ~= "backend"
    or not absolute_path(intent.backend.executable)
    or not decimal_identity(intent.backend.executable_dev, true)
    or not decimal_identity(intent.backend.executable_ino, false)
    or not safe_string(intent.backend.version, 128)
    or not is_integer(intent.backend.port, 1, 65535)
    or intent.backend.port == intent.public.port
    or intent.backend.log ~= paths().log
    or not has_only_fields(intent.proxy, {
      role = true,
      port = true,
      executable = true,
      executable_dev = true,
      executable_ino = true,
      source = true,
      source_dev = true,
      source_ino = true,
      log = true,
      argv = true,
      pid = "optional",
    })
    or intent.proxy.role ~= "proxy"
    or intent.proxy.port ~= intent.public.port
    or intent.proxy.executable ~= java21
    or not decimal_identity(intent.proxy.executable_dev, true)
    or not decimal_identity(intent.proxy.executable_ino, false)
    or intent.proxy.source ~= paths().proxy_source
    or not decimal_identity(intent.proxy.source_dev, true)
    or not decimal_identity(intent.proxy.source_ino, false)
    or intent.proxy.log ~= paths().proxy_log
    or not valid_argv(intent.proxy.argv)
    or (intent.proxy.pid ~= nil and not is_integer(intent.proxy.pid, 1, 4194304))
  then
    return false
  end
  return vim.deep_equal(intent.proxy.argv, {
    intent.proxy.executable,
    "--source",
    "21",
    intent.proxy.source,
    "--broker",
    "--state-root",
    paths().root,
    "--control",
    intent.control.path,
    "--generation",
    intent.generation,
    "--boot-id",
    intent.boot_id,
    "--backend-executable",
    intent.backend.executable,
    "--backend-version",
    intent.backend.version,
    "--backend-port",
    tostring(intent.backend.port),
    "--listen-port",
    tostring(intent.public.port),
    "--keystore",
    paths().server_store,
    "--password-file",
    paths().password,
    "--max-connections",
    tostring(proxy_max_connections),
    "--backend-log",
    intent.backend.log,
    "--pidfd-python",
    paths().pidfd_python,
    "--pidfd-helper",
    paths().pidfd_helper,
  })
end

local function valid_launch_intent(intent)
  if valid_broker_launch_intent(intent) then
    return true
  end
  return type(intent) == "table"
    and intent.schema == 1
    and intent.hostname == hostname()
    and valid_generation(intent.generation)
    and valid_boot_id(intent.boot_id)
    and (intent.role == "backend" or intent.role == "proxy")
    and is_integer(intent.port, 1, 65535)
    and (intent.pid == nil or is_integer(intent.pid, 1, 4194304))
end

local function read_launch_intent()
  local content = read_file(paths().launch)
  if not content then
    return nil, "missing"
  end
  local ok, intent = pcall(vim.json.decode, content)
  if not ok or type(intent) ~= "table" then
    return nil, "malformed"
  end
  if type(intent.schema) == "number" and intent.schema % 1 == 0 and intent.schema > 2 then
    return nil, "unsupported schema"
  end
  if not valid_launch_intent(intent) then
    return nil, "malformed"
  end
  return intent, "valid"
end

local function write_launch_intent(intent)
  if not valid_launch_intent(intent) then
    return nil, "refusing to write malformed launch intent"
  end
  local owned, ownership_err = require_lock_ownership("launch intent " .. intent.generation .. " write")
  if not owned then
    return nil, ownership_err
  end
  local temporary = paths().launch .. "." .. random_token() .. ".tmp"
  local wrote, write_err = write_private(temporary, vim.json.encode(intent), true)
  if not wrote then
    return nil, write_err
  end
  owned, ownership_err = require_lock_ownership("launch intent " .. intent.generation .. " publication")
  if not owned then
    uv.fs_unlink(temporary)
    return nil, ownership_err
  end
  local renamed, rename_err = uv.fs_rename(temporary, paths().launch)
  if not renamed then
    uv.fs_unlink(temporary)
    return nil, rename_err
  end
  return true
end

local function remove_matching_launch_intent(generation)
  local owned, ownership_err = require_lock_ownership("launch intent " .. generation .. " removal")
  if not owned then
    return nil, ownership_err
  end
  local intent, status = read_launch_intent()
  if not intent then
    return nil,
      status == "malformed" and "malformed launch intent requires manual inspection" or "launch intent is missing"
  end
  if intent.generation ~= generation then
    return nil, "launch intent generation changed; refusing stale removal"
  end
  local removed, remove_err = uv.fs_unlink(paths().launch)
  return removed or nil, remove_err
end

local ensure_waiters = {}
local ensure_active = false
local local_tui

local function finish_ensure(ok, err, state)
  local callbacks = ensure_waiters
  ensure_waiters = {}
  ensure_active = false
  if ok and not lifecycle_only then
    warn_no_password()
  end
  for _, callback in ipairs(callbacks) do
    callback(ok, err, state)
  end
end

local function tui_valid()
  if not local_tui or not local_tui.term or not local_tui.term:valid() then
    return false
  end
  local job = local_tui.job
  if type(job) ~= "number" or job <= 0 then
    return false
  end
  return vim.fn.jobwait({ job }, 0)[1] == -1
end

local function close_local_tui()
  if tui_valid() then
    local_tui.term:close()
  end
  local_tui = nil
end

local terminal_position = "default"
local terminal_sizes = {
  bottom = { height = 0.35 },
  top = { height = 0.35 },
  left = { width = 0.35 },
  right = { width = 0.35 },
  float = { height = 0.9, width = 0.9 },
}
local terminal_positions = vim.tbl_keys(terminal_sizes)
table.insert(terminal_positions, "default")
table.sort(terminal_positions)

local function terminal_opts(position)
  position = position or terminal_position
  if position == "default" then
    position = vim.o.columns >= vim.o.lines and "bottom" or "right"
  end
  return {
    win = vim.tbl_deep_extend("force", { position = position, enter = false }, terminal_sizes[position] or {}),
  }
end

local function ensure_local_tui(state, callback)
  local cwd = vim.fn.getcwd()
  if cwd == "" then
    callback(false, "Unable to determine the current Neovim directory")
    return
  end
  if
    tui_valid()
    and local_tui.url == state.url
    and local_tui.directory == cwd
    and local_tui.generation == state.generation
    and local_tui.transport == state_transport(state)
    and local_tui.certificate_identity == state.certificate_identity
  then
    callback(true)
    return
  end
  close_local_tui()
  local command = { "opencode", "attach", state.url, "--dir", cwd }
  local environment = state_transport(state) == "tls-proxy" and { NODE_EXTRA_CA_CERTS = state.ca_path } or nil
  local term, created = require("snacks.terminal").get(
    command,
    vim.tbl_deep_extend("force", terminal_opts(), {
      create = true,
      env = environment,
    })
  )
  if not term then
    callback(false, "Unable to create the local OpenCode attached TUI")
    return
  end
  local buffer = term.buf or term.bufnr
  local job = term.job or term.job_id
  if (not job or job <= 0) and buffer and vim.api.nvim_buf_is_valid(buffer) then
    job = vim.b[buffer].terminal_job_id
  end
  if type(job) ~= "number" or job <= 0 then
    callback(false, "OpenCode attached TUI did not expose a live terminal job")
    return
  end
  local_tui = {
    term = term,
    job = job,
    url = state.url,
    directory = cwd,
    generation = state.generation,
    transport = state_transport(state),
    certificate_identity = state.certificate_identity,
    command = command,
  }
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = buffer,
      once = true,
      callback = function()
        -- TermClose status is not a liveness signal: SIGKILL and normal exit
        -- are both dead local TUIs and must be recreated on the next operation.
        if local_tui and local_tui.term == term then
          local_tui = nil
        end
      end,
    })
  end
  if created then
    vim.defer_fn(function()
      callback(true)
    end, local_tui_bootstrap_ms)
  else
    callback(true)
  end
end

function test_hooks.broker_receipt_matches_backend(receipt, backend)
  local received = receipt and receipt.backend and vim.deepcopy(receipt.backend) or nil
  local recorded = backend and vim.deepcopy(backend) or nil
  if received then
    received.server_version = nil
  end
  if recorded then
    recorded.server_version = nil
  end
  return receipt and receipt.phase == "running" and vim.deep_equal(received, recorded)
end

function test_hooks.broker_receipt_matches_proxy(receipt, proxy)
  local received = receipt and receipt.proxy and vim.deepcopy(receipt.proxy) or nil
  local recorded = proxy and vim.deepcopy(proxy) or nil
  if received then
    received.log = paths().proxy_log
  end
  return received ~= nil and recorded ~= nil and vim.deep_equal(received, recorded)
end

function test_hooks.observe_broker(state, callback)
  local root_identity, root_err = test_hooks.read_authority_root()
  if not root_identity then
    callback(nil, root_err)
    return
  end
  local socket = private_socket_identity(state.broker.control_path, root_identity)
  if not socket or socket.dev ~= state.broker.control_dev or socket.ino ~= state.broker.control_ino then
    callback(nil, "broker control authority changed")
    return
  end
  broker_exchange(state.broker.control_path, "status", state.generation, root_identity, socket, callback)
end

local function managed_state_if_healthy(state, requested, callback)
  if not state then
    callback(nil, { kind = "missing" })
    return
  end
  if state.schema == 1 then
    callback(nil, { kind = "legacy", message = "schema 1 is legacy and is never probed" })
    return
  end
  if state_transport(state) ~= requested_transport() then
    callback(nil, {
      kind = "mode-mismatch",
      message = "Requested "
        .. requested_transport()
        .. " differs from active "
        .. state_transport(state)
        .. "; run :OpenCodeStop, restart Neovim, and start OpenCode again",
    })
    return
  end
  local function prove_endpoint_health()
    if state_transport(state) == "tls-proxy" then
      local identity = certificate_identity(paths())
      if state.ca_path ~= paths().ca or not identity or identity ~= state.certificate_identity then
        callback(nil, { kind = "owned-unhealthy", message = "certificate identity changed or is unavailable" })
        return
      end
    end
    probe_health(state, function(health, detail)
      if detail.kind == "unauthorized" then
        callback(nil, detail)
      elseif health then
        if safe_string(health.version, 128) then
          state.backend.server_version = health.version
        end
        if requested and state.port ~= requested then
          callback(nil, {
            kind = "explicit-port-conflict",
            message = "A managed OpenCode server uses "
              .. state.url
              .. "; stop the shared server before changing the configured port",
          })
        else
          callback(state, detail)
        end
      else
        callback(nil, { kind = "owned-unhealthy", message = detail.kind })
      end
    end, true)
  end
  local function prove_process_and_health()
    local owned, ownership = process_is_owned(state)
    if not owned then
      local proxy_live = state.proxy and pid_is_live(state.proxy.pid)
      local backend_live = state.backend and pid_is_live(state.backend.pid)
      if state_transport(state) == "loopback-http" and not backend_live then
        callback(nil, { kind = "owned-unhealthy", message = ownership })
      elseif state_transport(state) == "tls-proxy" and (not proxy_live or not backend_live) then
        callback(nil, { kind = "owned-unhealthy", message = ownership })
      else
        callback(nil, { kind = "unverifiable-pid", message = ownership })
      end
      return
    end
    if
      not process_listens_on_port(state.backend.pid, state.backend.port)
      or (state_transport(state) == "tls-proxy" and not process_listens_on_port(state.proxy.pid, state.port))
    then
      callback(nil, { kind = "owned-unhealthy", message = "managed listener ownership is missing" })
      return
    end
    prove_endpoint_health()
  end
  if state.schema ~= 4 then
    prove_process_and_health()
    return
  end
  test_hooks.observe_broker(state, function(receipt, receipt_err)
    if not receipt then
      local broker_live = pid_is_live(state.proxy.pid)
      local backend_live = pid_is_live(state.backend.pid)
      if not broker_live and not backend_live then
        callback(nil, { kind = "schema4-both-dead", message = receipt_err or "broker-and-backend-dead" })
      elseif not broker_live and backend_live then
        callback(nil, { kind = "schema4-broker-dead-backend-live", message = receipt_err })
      else
        callback(nil, { kind = "broker-unavailable", message = receipt_err })
      end
    elseif receipt.phase == "blocked" then
      callback(nil, { kind = "blocked", message = "broker-blocked" })
    elseif receipt.phase == "stopping" then
      callback(nil, { kind = "stopping", message = "broker-stopping" })
    elseif not test_hooks.broker_receipt_matches_proxy(receipt, state.proxy) then
      callback(nil, { kind = "unverifiable-pid", message = "broker-running-evidence-mismatch" })
    elseif not test_hooks.broker_receipt_matches_backend(receipt, state.backend) then
      callback(nil, { kind = "schema4-broker-live-backend-dead", message = "broker-running-evidence-mismatch" })
    else
      -- The broker receipt and independently pinned endpoint proof must agree.
      prove_endpoint_health()
    end
  end)
end

local function wait_for_listener(process, boot_id, port, deadline_ns, callback)
  local owned, reason = process_identity_is_owned(process, boot_id)
  if not owned then
    callback(false, reason)
  elseif process_listens_on_port(process.pid, port) then
    callback(true)
  elseif uv.hrtime() >= deadline_ns then
    callback(false, "process did not acquire its expected loopback listener")
  else
    vim.defer_fn(function()
      wait_for_listener(process, boot_id, port, deadline_ns, callback)
    end, health_interval_ms)
  end
end

local read_pending

local function stop_pair(state, deadline_ns, callback)
  local function stop_backend()
    if not state.backend or not pid_is_live(state.backend.pid) then
      callback(true)
      return
    end
    terminate_process(state.backend, state.boot_id, deadline_ns, callback)
  end
  if not state.proxy or not pid_is_live(state.proxy.pid) then
    stop_backend()
    return
  end
  terminate_process(state.proxy, state.boot_id, deadline_ns, function(stopped, err)
    if not stopped then
      callback(false, "proxy cleanup failed: " .. (err or "unknown error"))
      return
    end
    stop_backend()
  end)
end

-- Schema-4 never sends a signal from Lua.  The broker's final receipt is only
-- useful when its recorded process and control inode also disappear under this
-- caller's fence.
function test_hooks.stop_schema4(state, deadline_ns, callback)
  local function root_and_absent()
    local root_identity, root_err = test_hooks.read_authority_root()
    if not root_identity or not authority_root_is_stable(root_identity) then
      return nil, root_err or "broker authority root changed"
    end
    if uv.fs_lstat(state.broker.control_path) then
      return nil, "recorded broker control path remains present"
    end
    return true
  end
  local function reconcile_dead()
    local absent, absent_err = root_and_absent()
    if absent and not pid_is_live(state.proxy.pid) and (not state.backend or not pid_is_live(state.backend.pid)) then
      callback(true)
    else
      callback(false, absent_err or "schema-4 broker or backend remains live")
    end
  end
  if not pid_is_live(state.proxy.pid) then
    reconcile_dead()
    return
  end
  local root_identity, root_err = test_hooks.read_authority_root()
  if not root_identity then
    callback(false, root_err)
    return
  end
  local socket = private_socket_identity(state.broker.control_path, root_identity)
  if not socket or socket.dev ~= state.broker.control_dev or socket.ino ~= state.broker.control_ino then
    callback(false, "broker control authority changed")
    return
  end
  broker_exchange(
    state.broker.control_path,
    "stop",
    state.generation,
    root_identity,
    socket,
    function(receipt, receipt_err)
      if not receipt then
        callback(false, receipt_err or "broker stop receipt was lost")
        return
      end
      if receipt.phase ~= "stopped" then
        callback(false, "broker stop did not reach terminal state: " .. receipt.phase)
        return
      end
      local function wait_terminal()
        local absent, absent_err = root_and_absent()
        if
          absent
          and not pid_is_live(state.proxy.pid)
          and (not state.backend or not pid_is_live(state.backend.pid))
        then
          callback(true)
        elseif uv.hrtime() >= deadline_ns then
          callback(false, absent_err or "broker stop receipt arrived before recorded roles exited")
        else
          vim.defer_fn(wait_terminal, health_interval_ms)
        end
      end
      wait_terminal()
    end
  )
end

function test_hooks.remove_schema4_metadata_while_locked(state)
  local pending, pending_status = read_pending()
  if pending then
    if pending.schema ~= 4 or pending.generation ~= state.generation then
      return nil, "pending metadata does not match terminal schema-4 generation"
    end
  elseif pending_status == "malformed" or uv.fs_stat(paths().pending) then
    return nil, "malformed pending metadata blocks schema-4 cleanup"
  end
  local intent, intent_status = read_launch_intent()
  if intent then
    if intent.schema ~= 2 or intent.generation ~= state.generation then
      return nil, "launch intent does not match terminal schema-4 generation"
    end
  elseif intent_status == "malformed" or uv.fs_stat(paths().launch) then
    return nil, "malformed launch intent blocks schema-4 cleanup"
  end
  if pending then
    local pending_removed, pending_err =
      remove_matching_pending_while_locked(state.generation, "terminal schema-4 pending removal")
    if not pending_removed then
      return nil, pending_err
    end
  end
  if intent then
    local intent_removed, intent_err = remove_matching_launch_intent(state.generation)
    if not intent_removed then
      return nil, intent_err
    end
  end
  return remove_matching_state_while_locked(state.generation, "terminal schema-4 generation state removal")
end

local function stop_legacy(state, deadline_ns, callback)
  local owned, reason = legacy_process_is_owned(state)
  if not owned then
    callback(not pid_is_live(state.pid), reason)
    return
  end
  callback(false, reason)
end

read_pending = function()
  local content = read_file(paths().pending)
  if not content then
    return nil
  end
  local ok, pending = pcall(vim.json.decode, content)
  if ok and type(pending) == "table" then
    if type(pending.schema) == "number" and pending.schema % 1 == 0 and pending.schema > 4 then
      return nil, "unsupported schema"
    end
    if
      pending.schema == 4
      and type(pending.broker) == "table"
      and type(pending.broker.protocol) == "number"
      and pending.broker.protocol > 1
    then
      return nil, "unsupported broker protocol"
    end
  end
  if not ok or not valid_pending(pending) then
    return nil, "malformed"
  end
  return pending, "valid"
end

local function launch_intent_is_covered(intent, pending)
  if not intent or not pending or intent.generation ~= pending.generation or intent.boot_id ~= pending.boot_id then
    return false
  end
  if intent.schema == 2 then
    return pending.schema == 4
      and pending.proxy ~= nil
      and pending.broker ~= nil
      and pending.proxy.pid == intent.proxy.pid
      and pending.proxy.port == intent.proxy.port
      and pending.proxy.executable == intent.proxy.executable
      and pending.proxy.executable_dev == intent.proxy.executable_dev
      and pending.proxy.executable_ino == intent.proxy.executable_ino
      and pending.proxy.source == intent.proxy.source
      and pending.proxy.source_dev == intent.proxy.source_dev
      and pending.proxy.source_ino == intent.proxy.source_ino
      and vim.deep_equal(pending.proxy.argv, intent.proxy.argv)
      and pending.broker.protocol == intent.control.protocol
      and pending.broker.control_path == intent.control.path
  end
  local process = intent.role == "backend" and pending.backend or pending.proxy
  return process ~= nil and process.port == intent.port and (intent.pid == nil or process.pid == intent.pid)
end

local function matching_pending_while_locked(generation, action)
  local owned, ownership_err = require_lock_ownership(action)
  if not owned then
    return nil, ownership_err
  end
  local pending, status = read_pending()
  if not pending then
    if status == "malformed" or uv.fs_stat(paths().pending) then
      return nil, "malformed pending startup metadata requires manual inspection: " .. paths().pending
    end
    return nil, "pending startup metadata is missing for generation " .. generation
  end
  if pending.generation ~= generation then
    return nil,
      "pending startup generation changed from "
        .. generation
        .. " to "
        .. pending.generation
        .. "; refusing stale cleanup"
  end
  return pending
end

local function remove_matching_pending_while_locked(generation, action)
  local pending, pending_err = matching_pending_while_locked(generation, action or "pending generation removal")
  if not pending then
    return nil, pending_err
  end
  run_test_hook "pending_remove"
  local removed, remove_err = uv.fs_unlink(paths().pending)
  if not removed then
    return nil, remove_err or "unable to remove matching pending startup metadata"
  end
  return true
end

local function cleanup_pending(deadline_ns, callback)
  local owned, ownership_err = require_lock_ownership "interrupted pending startup inspection"
  if not owned then
    callback(false, ownership_err)
    return
  end
  local pending, status = read_pending()
  if not pending then
    if status == "malformed" or uv.fs_stat(paths().pending) then
      callback(false, "malformed pending startup metadata requires manual inspection: " .. paths().pending)
    else
      callback(true)
    end
    return
  end
  if pending.schema == 4 then
    test_hooks.stop_schema4(pending, deadline_ns, function(stopped, stop_err)
      if not stopped then
        callback(false, stop_err)
        return
      end
      local removed, remove_err =
        remove_matching_pending_while_locked(pending.generation, "terminal schema-4 pending removal")
      if not removed then
        callback(false, remove_err)
        return
      end
      local intent, intent_status = read_launch_intent()
      if intent_status == "missing" then
        callback(true)
      elseif not intent or intent.generation ~= pending.generation then
        callback(false, "launch intent does not match terminal schema-4 pending generation")
      else
        callback(remove_matching_launch_intent(pending.generation))
      end
    end)
    return
  end
  stop_pair(pending, deadline_ns, function(stopped, err)
    if stopped then
      local removed, remove_err =
        remove_matching_pending_while_locked(pending.generation, "interrupted pending generation removal")
      if not removed then
        callback(false, remove_err)
        return
      end
    end
    callback(stopped, err)
  end)
end

local function cleanup_failed_pair(state, deadline_ns, callback)
  local pending, pending_err = matching_pending_while_locked(state.generation, "failed pending generation cleanup")
  if not pending then
    callback(false, pending_err)
    return
  end
  if pending.schema == 4 then
    cleanup_pending(deadline_ns, callback)
    return
  end
  stop_pair(pending, deadline_ns, function(stopped, err)
    if stopped then
      local removed, remove_err =
        remove_matching_pending_while_locked(state.generation, "failed pending generation removal")
      if not removed then
        callback(false, remove_err)
        return
      end
    end
    callback(stopped, err)
  end)
end

local function spawn_direct(previous, deadline_ns, callback, excluded_public)
  local fenced, fence_err = require_fence "managed direct backend launch"
  if not fenced then
    callback(nil, fence_err)
    return
  end
  local state_paths = paths()
  resolve_executable(deadline_ns, function(executable, version, executable_err)
    if not executable then
      callback(nil, executable_err or "Unable to find OpenCode on PATH")
      return
    end
    local backend_executable = file_identity(executable)
    if not backend_executable then
      callback(nil, "Unable to record backend executable identity before launch")
      return
    end
    local public_port, source, public_err = select_port(previous, excluded_public)
    if not public_port then
      callback(nil, public_err .. "; see " .. state_paths.log)
      return
    end
    local boot_id = current_boot_id()
    if not boot_id then
      callback(nil, "Unable to read the host boot identity")
      return
    end
    local generation = random_token()
    local launch_intent = {
      schema = 1,
      hostname = hostname(),
      generation = generation,
      boot_id = boot_id,
      role = "backend",
      port = public_port,
    }
    local intent_ok, intent_err = write_launch_intent(launch_intent)
    if not intent_ok then
      callback(nil, "Unable to record direct backend launch intent: " .. (intent_err or "unknown error"))
      return
    end
    local backend_pid, backend_spawn_err =
      spawn_detached(executable, { "serve", "--hostname", host, "--port", tostring(public_port) }, state_paths.log)
    if not backend_pid then
      local removed, remove_err = remove_matching_launch_intent(generation)
      callback(
        nil,
        "Unable to launch OpenCode backend: "
          .. backend_spawn_err
          .. (remove_err and "; launch intent removal failed: " .. remove_err or "")
          .. "; see "
          .. state_paths.log,
        removed and public_port or nil
      )
      return
    end
    launch_intent.pid = backend_pid
    write_launch_intent(launch_intent)
    vim.defer_fn(function()
      local backend, capture_err = capture_process(backend_pid, {
        port = public_port,
        executable = executable,
        executable_dev = backend_executable.dev,
        executable_ino = backend_executable.ino,
        local_version = version,
        log = state_paths.log,
      })
      if not backend then
        local live = pid_is_live(backend_pid)
        local removed, remove_err
        if not live then
          removed, remove_err = remove_matching_launch_intent(generation)
        end
        callback(
          nil,
          "OpenCode backend "
            .. capture_err
            .. (live and "; spawned PID remains live and requires manual accounting" or "")
            .. (remove_err and "; launch intent removal failed: " .. remove_err or "")
            .. "; see "
            .. state_paths.log,
          removed and public_port or nil
        )
        return
      end
      local pending = {
        schema = 3,
        transport = "loopback-http",
        hostname = hostname(),
        generation = generation,
        boot_id = boot_id,
        port = public_port,
        backend = backend,
      }
      local pending_ok, pending_err = write_pending(pending)
      if not pending_ok then
        terminate_process(backend, boot_id, deadline_ns, function(cleaned, cleanup_err)
          local intent_removed, intent_remove_err
          if cleaned then
            intent_removed, intent_remove_err = remove_matching_launch_intent(generation)
          end
          callback(
            nil,
            "Unable to record pending backend identity: "
              .. (pending_err or "unknown error")
              .. (cleanup_err and "; backend cleanup refused: " .. cleanup_err or "")
              .. (intent_remove_err and "; launch intent removal failed: " .. intent_remove_err or ""),
            cleaned and intent_removed and public_port or nil
          )
        end)
        return
      end
      local intent_removed, intent_remove_err = remove_matching_launch_intent(generation)
      if not intent_removed then
        cleanup_failed_pair(pending, deadline_ns, function(_, cleanup_err)
          callback(
            nil,
            "Pending backend identity was recorded but launch intent removal failed: "
              .. (intent_remove_err or "unknown error")
              .. (cleanup_err and "; " .. cleanup_err or "")
          )
        end)
        return
      end
      wait_for_listener(backend, boot_id, public_port, deadline_ns, function(backend_ready, backend_err)
        if not backend_ready then
          cleanup_failed_pair(pending, deadline_ns, function(cleaned, cleanup_err)
            callback(
              nil,
              "OpenCode direct backend listener failed: "
                .. backend_err
                .. (cleanup_err and "; " .. cleanup_err or "")
                .. "; see "
                .. state_paths.log,
              cleaned and public_port or nil
            )
          end)
          return
        end
        local state = {
          schema = 3,
          transport = "loopback-http",
          hostname = hostname(),
          generation = generation,
          host = host,
          port = public_port,
          url = ("http://%s:%d"):format(host, public_port),
          port_source = source,
          started_at = iso_now(),
          cwd = vim.env.HOME or vim.fn.expand "~",
          boot_id = boot_id,
          backend = backend,
        }
        local function wait_for_health()
          local backend_owned = process_is_owned(state)
          if not backend_owned or not process_listens_on_port(backend.pid, public_port) then
            cleanup_failed_pair(state, deadline_ns, function(cleaned, cleanup_err)
              callback(
                nil,
                "Managed direct backend identity was lost before readiness"
                  .. (cleanup_err and "; " .. cleanup_err or ""),
                cleaned and public_port or nil
              )
            end)
            return
          end
          probe_health(state, function(health, detail)
            if health then
              state.backend.server_version = health.version
              local wrote, state_err = write_state_while_locked(state, "complete schema-3 direct state publication")
              if not wrote then
                cleanup_failed_pair(state, deadline_ns, function(cleaned, cleanup_err)
                  callback(
                    nil,
                    state_err .. (cleanup_err and "; " .. cleanup_err or ""),
                    cleaned and public_port or nil
                  )
                end)
                return
              end
              local removed, remove_err =
                remove_matching_pending_while_locked(generation, "successful direct pending generation removal")
              if not removed then
                callback(
                  nil,
                  "Complete direct state was published but pending metadata could not be removed: " .. remove_err
                )
                return
              end
              callback(state)
            elseif uv.hrtime() >= deadline_ns or detail.kind == "unauthorized" then
              cleanup_failed_pair(state, deadline_ns, function(cleaned, cleanup_err)
                callback(
                  nil,
                  "Direct HTTP health failed ("
                    .. detail.kind
                    .. (detail.message and ": " .. detail.message or "")
                    .. (cleanup_err and "; " .. cleanup_err or "")
                    .. "; see "
                    .. state_paths.log,
                  cleaned and public_port or nil
                )
              end)
            else
              vim.defer_fn(wait_for_health, health_interval_ms)
            end
          end, true)
        end
        wait_for_health()
      end)
    end, 50)
  end)
end

local function spawn_broker_pair(previous, deadline_ns, callback, excluded_public, excluded_internal)
  local state_paths, root_err = ensure_state_dir()
  if not state_paths then
    return callback(nil, root_err)
  end
  local root_identity = state_paths.root_identity
  ensure_certificate_material(deadline_ns, function(certificate, certificate_err)
    if not certificate then
      return callback(nil, "Unable to prepare host TLS certificate material: " .. certificate_err)
    end
    resolve_executable(deadline_ns, function(executable, version, executable_err)
      if
        not executable
        or state_paths.pidfd_python == ""
        or not uv.fs_stat(java21)
        or not uv.fs_stat(state_paths.proxy_source)
        or not uv.fs_stat(state_paths.pidfd_helper)
      then
        return callback(nil, executable_err or "Java 21 broker or OpenCode executable is unavailable")
      end
      local backend_executable, proxy_executable, proxy_source =
        file_identity(executable), file_identity(java21), file_identity(state_paths.proxy_source)
      if not backend_executable or not proxy_executable or not proxy_source then
        return callback(nil, "Unable to record broker launch identities")
      end
      local public_port, source, public_err = select_port(previous, excluded_public)
      local internal_port, internal_err =
        public_port and select_internal_port(public_port, excluded_internal) or nil, nil
      if public_port then
        internal_port, internal_err = select_internal_port(public_port, excluded_internal)
      end
      if not public_port or not internal_port then
        return callback(nil, public_err or internal_err)
      end
      local boot_id, generation = current_boot_id(), random_token()
      if not boot_id then
        return callback(nil, "Unable to read the host boot identity")
      end
      local arguments = {
        "--source",
        "21",
        state_paths.proxy_source,
        "--broker",
        "--state-root",
        state_paths.root,
        "--control",
        state_paths.control,
        "--generation",
        generation,
        "--boot-id",
        boot_id,
        "--backend-executable",
        executable,
        "--backend-version",
        version,
        "--backend-port",
        tostring(internal_port),
        "--listen-port",
        tostring(public_port),
        "--keystore",
        state_paths.server_store,
        "--password-file",
        state_paths.password,
        "--max-connections",
        tostring(proxy_max_connections),
        "--backend-log",
        state_paths.log,
        "--pidfd-python",
        state_paths.pidfd_python,
        "--pidfd-helper",
        state_paths.pidfd_helper,
      }
      local intent = {
        schema = 2,
        transport = "tls-proxy",
        hostname = hostname(),
        generation = generation,
        boot_id = boot_id,
        proxy = {
          role = "proxy",
          port = public_port,
          executable = java21,
          executable_dev = proxy_executable.dev,
          executable_ino = proxy_executable.ino,
          source = state_paths.proxy_source,
          source_dev = proxy_source.dev,
          source_ino = proxy_source.ino,
          log = state_paths.proxy_log,
          argv = vim.list_extend({ java21 }, vim.deepcopy(arguments)),
        },
        public = { role = "public", port = public_port },
        control = { protocol = 1, path = state_paths.control },
        backend = {
          role = "backend",
          executable = executable,
          executable_dev = backend_executable.dev,
          executable_ino = backend_executable.ino,
          version = version,
          port = internal_port,
          log = state_paths.log,
        },
      }
      local intent_ok, intent_err = write_launch_intent(intent)
      if not intent_ok then
        return callback(nil, "Unable to record TLS broker launch intent: " .. (intent_err or "unknown error"))
      end
      if not uv.fs_stat(state_paths.log) then
        local created, create_err = write_private(state_paths.log, "", true)
        if not created then
          return callback(nil, "Unable to create backend broker log: " .. (create_err or "unknown error"))
        end
      end
      local proxy_pid, spawn_err = spawn_detached(java21, arguments, state_paths.proxy_log)
      if not proxy_pid then
        return callback(nil, "Unable to launch TLS broker: " .. spawn_err)
      end
      intent.proxy.pid = proxy_pid
      if not write_launch_intent(intent) then
        return callback(nil, "Broker launch intent could not record its PID")
      end
      vim.defer_fn(function()
        local control = private_socket_identity(state_paths.control, root_identity)
        local proxy, capture_err = capture_process(proxy_pid, {
          port = public_port,
          executable = java21,
          executable_dev = proxy_executable.dev,
          executable_ino = proxy_executable.ino,
          source = state_paths.proxy_source,
          source_dev = proxy_source.dev,
          source_ino = proxy_source.ino,
          log = state_paths.proxy_log,
        })
        if not control or not proxy then
          return callback(
            nil,
            "Broker control readiness could not be proved: " .. (capture_err or "socket unavailable")
          )
        end
        broker_exchange(
          state_paths.control,
          "status",
          generation,
          root_identity,
          control,
          function(receipt, receipt_err)
            if
              not receipt
              or receipt.phase ~= "control-ready"
              or not test_hooks.broker_receipt_matches_proxy(receipt, proxy)
            then
              return callback(nil, "Broker control readiness failed: " .. (receipt_err or "unexpected phase"))
            end
            local broker =
              { protocol = 1, control_path = state_paths.control, control_dev = control.dev, control_ino = control.ino }
            local pending = {
              schema = 4,
              transport = "tls-proxy",
              phase = "control-ready",
              hostname = hostname(),
              generation = generation,
              boot_id = boot_id,
              proxy = proxy,
              broker = broker,
            }
            local pending_ok, pending_err = write_pending(pending)
            if not pending_ok then
              return callback(nil, "Unable to publish control-ready broker state: " .. pending_err)
            end
            broker_exchange(
              state_paths.control,
              "activate",
              generation,
              root_identity,
              control,
              function(activated, activation_err)
                if not activated or activated.phase ~= "running" or type(activated.backend) ~= "table" then
                  return cleanup_failed_pair(pending, deadline_ns, function(cleaned, cleanup_err)
                    callback(
                      nil,
                      "Broker activation failed: "
                        .. (activation_err or "backend evidence unavailable")
                        .. (cleanup_err and "; broker cleanup failed: " .. cleanup_err or ""),
                      cleaned and public_port or nil,
                      cleaned and internal_port or nil
                    )
                  end)
                end
                local backend = activated.backend
                backend.server_version = nil
                pending.phase, pending.backend = "running", backend
                if not valid_pending(pending) then
                  return callback(nil, "Broker returned malformed backend evidence")
                end
                local running_ok, running_err = write_pending(pending)
                if not running_ok then
                  return callback(nil, "Unable to publish running broker state: " .. running_err)
                end
                local state = {
                  schema = 4,
                  transport = "tls-proxy",
                  hostname = hostname(),
                  generation = generation,
                  host = host,
                  port = public_port,
                  url = ("https://%s:%d"):format(host, public_port),
                  port_source = source,
                  started_at = iso_now(),
                  cwd = vim.env.HOME or vim.fn.expand "~",
                  boot_id = boot_id,
                  ca_path = state_paths.ca,
                  certificate_identity = certificate,
                  proxy = proxy,
                  backend = backend,
                  broker = broker,
                }
                local function ready()
                  probe_health(state, function(health, detail)
                    if health then
                      state.backend.server_version = health.version
                      local wrote, write_err =
                        write_state_while_locked(state, "complete schema-4 TLS state publication")
                      if not wrote then
                        return callback(nil, write_err)
                      end
                      local removed, remove_err =
                        remove_matching_pending_while_locked(generation, "successful schema-4 pending removal")
                      if not removed then
                        return callback(nil, remove_err)
                      end
                      remove_matching_launch_intent(generation)
                      return callback(state)
                    end
                    if uv.hrtime() >= deadline_ns or detail.kind == "unauthorized" then
                      return callback(nil, "Pinned HTTPS health failed (" .. detail.kind .. ")")
                    end
                    vim.defer_fn(ready, health_interval_ms)
                  end, true)
                end
                ready()
              end
            )
          end
        )
      end, 3000)
    end)
  end)
end

local function spawn_pair(previous, deadline_ns, callback, excluded_public, excluded_internal)
  if requested_transport() == "loopback-http" then
    spawn_direct(previous, deadline_ns, callback, excluded_public)
    return
  end
  return spawn_broker_pair(previous, deadline_ns, callback, excluded_public, excluded_internal)
end

local function ensure_backend(callback, attach_tui)
  attach_tui = attach_tui ~= false
  table.insert(ensure_waiters, callback)
  if ensure_active then
    return
  end
  ensure_active = true
  local operation_timeout_ms = startup_timeout_ms
  if vim.g.mkchad_opencode_test_api and is_integer(vim.g.mkchad_opencode_test_timeout_ms, 100, startup_timeout_ms) then
    operation_timeout_ms = vim.g.mkchad_opencode_test_timeout_ms
  end
  local deadline_ns = uv.hrtime() + operation_timeout_ms * 1000000
  local function finish_started(state)
    if not attach_tui then
      finish_ensure(true, nil, state)
      return
    end
    ensure_local_tui(state, function(ok, err)
      finish_ensure(ok, err, state)
    end)
  end
  local state, initial_status = read_state()
  local requested, request_err = explicit_port()
  if request_err then
    finish_ensure(false, request_err)
    return
  end
  local function detail_error(detail, endpoint_state)
    if detail.kind == "unauthorized" then
      return "OpenCode authentication failed at "
        .. (endpoint_state and endpoint_state.url or "the managed endpoint")
        .. " (HTTP 401)"
    elseif detail.kind == "explicit-port-conflict" then
      return detail.message
    elseif detail.kind == "unverifiable-pid" then
      return "Refusing to replace a live unverifiable managed process: " .. (detail.message or "ownership mismatch")
    elseif detail.kind == "mode-mismatch" then
      return detail.message
    end
  end
  local function start_while_locked(attempt, excluded_public, excluded_internal)
    if not require_lock_ownership "startup critical section" then
      release_lock()
      finish_ensure(false, "OpenCode startup lock ownership was lost before the critical section")
      return
    end
    local unresolved_intent, unresolved_status = read_launch_intent()
    if unresolved_status ~= "missing" then
      local covered_pending = read_pending()
      if launch_intent_is_covered(unresolved_intent, covered_pending) then
        if unresolved_intent.schema == 2 then
          -- Keep the intent until cleanup_pending obtains a matching terminal
          -- receipt from the exact recorded control inode.
        else
          local removed, remove_err = remove_matching_launch_intent(unresolved_intent.generation)
          if not removed then
            release_lock()
            finish_ensure(false, "Unable to reconcile covered launch intent: " .. (remove_err or "unknown error"))
            return
          end
        end
        unresolved_intent, unresolved_status = nil, "missing"
      end
    end
    if unresolved_status ~= "missing" then
      release_lock()
      finish_ensure(
        false,
        unresolved_intent
            and ("Refusing startup while unresolved " .. (unresolved_intent.schema == 2 and "broker" or unresolved_intent.role) .. " launch intent " .. unresolved_intent.generation .. (unresolved_intent.pid and (" records PID " .. unresolved_intent.pid) or "") .. "; use trusted OS process accounting before retrying")
          or ("Refusing startup because malformed launch intent requires manual inspection: " .. paths().launch)
      )
      return
    end
    local locked_state, locked_status = read_state()
    managed_state_if_healthy(locked_state, requested, function(rechecked, detail)
      if rechecked then
        release_lock()
        finish_started(rechecked)
        return
      end
      local hard_error = detail_error(detail, locked_state)
      if hard_error then
        release_lock()
        finish_ensure(false, hard_error)
        return
      end
      local function launch(previous)
        if not require_lock_ownership "server launch" then
          release_lock()
          finish_ensure(false, "OpenCode startup lock ownership was lost before launch")
          return
        end
        spawn_pair(previous, deadline_ns, function(started, start_err, failed_public, failed_internal)
          if
            not started
            and not requested
            and (failed_public or failed_internal)
            and attempt < 2
            and uv.hrtime() < deadline_ns
          then
            if not require_lock_ownership "automatic startup retry" then
              release_lock()
              finish_ensure(false, "OpenCode startup lock ownership was lost before automatic retry")
              return
            end
            excluded_public = excluded_public or {}
            excluded_internal = excluded_internal or {}
            if failed_public then
              excluded_public[failed_public] = true
            end
            if failed_internal then
              excluded_internal[failed_internal] = true
            end
            start_while_locked(attempt + 1, excluded_public, excluded_internal)
            return
          end
          release_lock()
          if not started then
            finish_ensure(false, start_err)
            return
          end
          finish_started(started)
        end)
      end
      local function after_pending_cleanup()
        if locked_status == "unsupported schema" or locked_status == "unsupported broker protocol" then
          release_lock()
          finish_ensure(false, "Refusing to replace unsupported future OpenCode authority")
        elseif locked_status == "malformed" then
          local removed, remove_err = remove_malformed_state_while_locked "malformed lifecycle state removal"
          if not removed then
            release_lock()
            finish_ensure(false, remove_err)
            return
          end
          launch(nil)
        elseif detail.kind == "legacy" and locked_state then
          stop_legacy(locked_state, deadline_ns, function(cleaned, cleanup_err)
            if not cleaned then
              release_lock()
              finish_ensure(
                false,
                "Legacy OpenCode process could not be safely stopped: " .. (cleanup_err or "unknown error")
              )
              return
            end
            local removed, remove_err =
              remove_matching_state_while_locked(locked_state.generation, "legacy state migration")
            if not removed then
              release_lock()
              finish_ensure(false, remove_err)
              return
            end
            launch(locked_state)
          end)
        elseif locked_state and locked_state.schema == 4 and detail.kind == "schema4-both-dead" then
          local reclaimed, reclaim_err = test_hooks.reclaim_dead_schema4_control_while_locked(locked_state)
          if not reclaimed then
            release_lock()
            finish_ensure(false, reclaim_err)
            return
          end
          local removed, remove_err =
            remove_matching_state_while_locked(locked_state.generation, "dead schema-4 generation state removal")
          if not removed then
            release_lock()
            finish_ensure(false, remove_err)
            return
          end
          launch(locked_state)
        elseif locked_state and locked_state.schema == 4 then
          release_lock()
          finish_ensure(
            false,
            "Schema-4 broker recovery requires committed broker cleanup; state was preserved: "
              .. (detail.message or detail.kind)
          )
        elseif detail.kind == "owned-unhealthy" then
          stop_pair(locked_state, deadline_ns, function(cleaned, cleanup_err)
            if not cleaned then
              release_lock()
              finish_ensure(
                false,
                "Managed OpenCode pair is unhealthy and cleanup failed: " .. (cleanup_err or "unknown error")
              )
              return
            end
            local removed, remove_err =
              remove_matching_state_while_locked(locked_state.generation, "unhealthy generation state removal")
            if not removed then
              release_lock()
              finish_ensure(false, remove_err)
              return
            end
            launch(locked_state)
          end)
        elseif detail.kind == "stale" and locked_state then
          local removed, remove_err = remove_matching_state_while_locked(locked_state.generation, "stale state removal")
          if not removed then
            release_lock()
            finish_ensure(false, remove_err)
            return
          end
          launch(locked_state)
        else
          launch(locked_state)
        end
      end
      cleanup_pending(deadline_ns, function(cleaned, cleanup_err)
        if not cleaned then
          release_lock()
          finish_ensure(false, "Unable to clean interrupted OpenCode startup: " .. (cleanup_err or "unknown error"))
          return
        end
        after_pending_cleanup()
      end)
    end)
  end
  managed_state_if_healthy(state, requested, function(healthy_state, detail)
    if healthy_state then
      finish_started(healthy_state)
      return
    end
    local hard_error = detail_error(detail, state)
    if hard_error then
      finish_ensure(false, hard_error)
      return
    end
    acquire_lock(function(locked, lock_err)
      if not locked then
        local function wait_for_winner()
          local waiting_state = read_state()
          managed_state_if_healthy(waiting_state, requested, function(winner, winner_detail)
            if winner then
              finish_started(winner)
              return
            end
            local winner_error = detail_error(winner_detail, waiting_state)
            if winner_error then
              finish_ensure(false, winner_error)
            elseif uv.hrtime() >= deadline_ns then
              acquire_lock(function(relocked, retry_err)
                if relocked then
                  start_while_locked(1)
                else
                  finish_ensure(false, retry_err or lock_err)
                end
              end, true, deadline_ns)
            else
              vim.defer_fn(wait_for_winner, health_interval_ms)
            end
          end)
        end
        wait_for_winner()
        return
      end
      start_while_locked(1)
    end, nil, deadline_ns)
  end)
end

-- The editor never owns a detached server generation.  It consumes the
-- versioned result from the installed command instead, retaining only the
-- endpoint data needed for its local client and attached TUI.
local command_adapter = {
  timeout_ms = startup_timeout_ms + 10000,
  endpoint_cache = nil,
  endpoint_epoch = 0,
}

function command_adapter.safe_string(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum and not value:find "[%z\1-\31\127]"
end

function command_adapter.complete_json_object(value)
  if type(value) ~= "string" or value:sub(1, 1) ~= "{" or value:sub(-1) == "\n" then
    return false
  end
  local depth = 0
  local quoted = false
  local escaped = false
  for index = 1, #value do
    local byte = value:byte(index)
    if quoted then
      if escaped then
        escaped = false
      elseif byte == 92 then
        escaped = true
      elseif byte == 34 then
        quoted = false
      end
    elseif byte == 34 then
      quoted = true
    elseif byte == 123 then
      depth = depth + 1
    elseif byte == 125 then
      depth = depth - 1
      if depth == 0 then
        return index == #value
      elseif depth < 0 then
        return false
      end
    end
  end
  return false
end

function command_adapter.endpoint_state(value)
  if type(value) ~= "table" then
    return nil
  end
  local url = value.url
  local transport = value.transport
  local generation = value.generation
  local ca_cert = value.ca_cert
  local server_version = value.server_version
  local port = type(url) == "string" and tonumber(url:match "^https?://127%.0%.0%.1:(%d+)$") or nil
  if not port or port < 1 or port > 65535 or not command_adapter.safe_string(generation, 256) then
    return nil
  end
  if server_version ~= nil and not command_adapter.safe_string(server_version, 128) then
    return nil
  end
  if transport == "tls-proxy" then
    if
      not url:match "^https://127%.0%.0%.1:%d+$"
      or not command_adapter.safe_string(ca_cert, 4096)
      or ca_cert:sub(1, 1) ~= "/"
    then
      return nil
    end
  elseif transport == "loopback-http" then
    if not url:match "^http://127%.0%.0%.1:%d+$" or ca_cert ~= vim.NIL then
      return nil
    end
  else
    return nil
  end
  return {
    url = url,
    transport = transport,
    generation = generation,
    ca_cert = ca_cert,
    server_version = server_version,
  }
end

function command_adapter.decode(action, stdout)
  if type(stdout) ~= "string" or #stdout == 0 or #stdout > subprocess_output_limit or stdout:sub(-1) ~= "\n" then
    return nil, "mkchad-opencode-server returned empty or oversized machine output"
  end
  local json = stdout:sub(1, -2)
  if not command_adapter.complete_json_object(json) then
    return nil, "mkchad-opencode-server returned malformed or trailing machine output"
  end
  local decoded_ok, result = pcall(vim.json.decode, json)
  if not decoded_ok or type(result) ~= "table" then
    return nil, "mkchad-opencode-server returned malformed machine output"
  end
  if
    result.schema ~= 1
    or type(result.ok) ~= "boolean"
    or result.command ~= action
    or type(result.status) ~= "string"
  then
    return nil, "mkchad-opencode-server returned an unsupported machine result"
  end
  if result.diagnostic ~= nil then
    if
      type(result.diagnostic) ~= "table"
      or not command_adapter.safe_string(result.diagnostic.code, 128)
      or not result.diagnostic.code:match "^[a-z0-9_]+$"
      or not command_adapter.safe_string(result.diagnostic.message, 1024)
    then
      return nil, "mkchad-opencode-server returned an invalid observation diagnostic"
    end
  end
  if result.ok then
    if result.status == "healthy" then
      result.state = command_adapter.endpoint_state(result.state)
      if not result.state then
        return nil, "mkchad-opencode-server returned an inconsistent endpoint"
      end
    elseif
      (
        result.status == "inactive"
        or result.status == "unhealthy"
        or result.status == "stopping"
        or result.status == "blocked"
      ) and result.state == vim.NIL
    then
      -- An observational result has no endpoint unless it is healthy.
      result.state = nil
    else
      return nil, "mkchad-opencode-server returned an inconsistent status result"
    end
    if action == "start" and (result.status ~= "healthy" or not result.state) then
      return nil, "mkchad-opencode-server did not start a healthy endpoint"
    end
    if action == "stop" and result.status ~= "inactive" then
      return nil, "mkchad-opencode-server returned an inconsistent stop result"
    end
    return result, nil, true
  end
  if
    result.status ~= "blocked"
    or type(result.error) ~= "table"
    or type(result.error.code) ~= "string"
    or not result.error.code:match "^[a-z0-9_]+$"
    or not command_adapter.safe_string(result.error.message, 1024)
  then
    return nil, "mkchad-opencode-server returned an invalid failure result"
  end
  return nil, "mkchad-opencode-server: " .. result.error.message, true
end

function command_adapter.argv(action)
  local argv
  if vim.g.mkchad_opencode_test_api and type(vim.g.mkchad_opencode_test_command_argv) == "table" then
    argv = vim.deepcopy(vim.g.mkchad_opencode_test_command_argv)
  else
    if not command_adapter.safe_string(vim.env.HOME, 4096) or vim.env.HOME:sub(1, 1) ~= "/" then
      return nil, "Unable to locate installed mkchad-opencode-server: HOME must be an absolute path"
    end
    local bin = vim.fs.joinpath(vim.env.HOME, ".local", "bin")
    local image_command = vim.fs.joinpath(bin, "mkchad-opencode-server-image")
    local executable = vim.fn.executable(image_command) == 1 and image_command
      or vim.fs.joinpath(bin, "mkchad-opencode-server")
    argv = { executable }
  end
  table.insert(argv, action)
  table.insert(argv, "--json")
  return argv
end

function command_adapter.invoke(action, callback)
  local argv, argv_err = command_adapter.argv(action)
  if not argv then
    vim.schedule(function()
      safe_subprocess_callback(callback, nil, argv_err)
    end)
    return
  end
  run_subprocess(argv, { timeout_ms = command_adapter.timeout_ms }, function(result, command_err)
    local parsed, parse_err, decoded
    if result and type(result.stdout) == "string" and result.stdout ~= "" then
      parsed, parse_err, decoded = command_adapter.decode(action, result.stdout)
    end
    if command_err or not result or result.code ~= 0 then
      if decoded and not parsed then
        callback(nil, parse_err)
      else
        local message = "mkchad-opencode-server " .. action .. " failed"
        if command_adapter.safe_string(command_err, 1024) then
          message = message .. ": " .. command_err
        end
        callback(nil, message)
      end
      return
    end
    callback(parsed, parse_err)
  end)
end

function command_adapter.cached_endpoint()
  if not command_adapter.endpoint_cache then
    return nil
  end
  return {
    schema = 3,
    url = command_adapter.endpoint_cache.url,
    transport = command_adapter.endpoint_cache.transport,
    generation = command_adapter.endpoint_cache.generation,
    ca_path = command_adapter.endpoint_cache.ca_cert,
    server_version = command_adapter.endpoint_cache.server_version,
  }
end

function command_adapter.ensure(callback)
  command_adapter.endpoint_epoch = command_adapter.endpoint_epoch + 1
  local epoch = command_adapter.endpoint_epoch
  command_adapter.endpoint_cache = nil
  command_adapter.invoke("start", function(result, command_err)
    if epoch ~= command_adapter.endpoint_epoch then
      callback(false, "OpenCode lifecycle command result was superseded")
    elseif not result then
      command_adapter.endpoint_cache = nil
      callback(false, command_err)
    else
      command_adapter.endpoint_cache = result.state
      callback(true, nil, command_adapter.cached_endpoint())
    end
  end)
end

function command_adapter.status(callback)
  command_adapter.invoke("status", function(result, command_err)
    if result then
      callback(result.status, result.state, result.diagnostic and result.diagnostic.message or nil)
    else
      callback("blocked", nil, command_err)
    end
  end)
end

function command_adapter.stop(callback)
  command_adapter.endpoint_epoch = command_adapter.endpoint_epoch + 1
  command_adapter.endpoint_cache = nil
  command_adapter.invoke("stop", function(result, command_err)
    callback(result ~= nil, command_err)
  end)
end

local function show_local_tui(toggle)
  command_adapter.ensure(function(ok, err, state)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    ensure_local_tui(state, function(tui_ok, tui_err)
      if not tui_ok then
        notify(tui_err, vim.log.levels.ERROR)
      elseif toggle then
        local_tui.term:toggle()
      else
        local_tui.term:show()
      end
    end)
  end)
end

local function stop_shared_server()
  local stop_timeout_ms = startup_timeout_ms
  if
    vim.g.mkchad_opencode_test_api
    and is_integer(vim.g.mkchad_opencode_test_stop_timeout_ms, 100, startup_timeout_ms)
  then
    stop_timeout_ms = vim.g.mkchad_opencode_test_stop_timeout_ms
  end
  acquire_lock(function(locked, lock_err)
    if not locked then
      notify(lock_err, vim.log.levels.ERROR)
      return
    end
    local state, state_status = read_state()
    if not state then
      local intent, intent_status = read_launch_intent()
      local pending = read_pending()
      if launch_intent_is_covered(intent, pending) then
        if intent.schema ~= 2 then
          local removed, remove_err = remove_matching_launch_intent(intent.generation)
          if not removed then
            release_lock()
            notify(
              "Unable to reconcile covered launch intent: " .. (remove_err or "unknown error"),
              vim.log.levels.ERROR
            )
            return
          end
        end
        cleanup_pending(uv.hrtime() + startup_timeout_ms * 1000000, function(cleaned, cleanup_err)
          release_lock()
          if not cleaned then
            notify(
              "Unable to stop covered pending generation: " .. (cleanup_err or "unknown error"),
              vim.log.levels.ERROR
            )
            return
          end
          close_local_tui()
          notify("Stopped pending OpenCode generation after launch-intent reconciliation", vim.log.levels.INFO)
        end)
        return
      end
      release_lock()
      close_local_tui()
      if intent_status ~= "missing" then
        notify(
          intent
              and ("Refusing stop without signal authority for unresolved " .. intent.role .. " launch intent " .. intent.generation .. (intent.pid and (" recording PID " .. intent.pid) or "") .. "; use trusted OS process accounting and remove " .. paths().launch .. " only after the role is confirmed dead")
            or ("Malformed launch intent requires manual inspection: " .. paths().launch),
          vim.log.levels.WARN
        )
      else
        notify("No managed shared OpenCode server is active (state " .. state_status .. ")", vim.log.levels.INFO)
      end
      return
    end
    if state.schema == 1 then
      stop_legacy(state, uv.hrtime() + stop_timeout_ms * 1000000, function(stopped, stop_err)
        if stopped then
          local removed, remove_err = remove_matching_state_while_locked(state.generation, "explicit legacy stop")
          release_lock()
          if not removed then
            notify(remove_err, vim.log.levels.ERROR)
            return
          end
          close_local_tui()
          notify("Removed dead legacy OpenCode state", vim.log.levels.INFO)
        else
          release_lock()
          notify(
            "Refusing to stop legacy OpenCode server: " .. (stop_err or "ownership mismatch"),
            vim.log.levels.ERROR
          )
        end
      end)
      return
    end
    if state.schema == 4 then
      test_hooks.stop_schema4(state, uv.hrtime() + stop_timeout_ms * 1000000, function(stopped, stop_err)
        if not stopped then
          release_lock()
          notify("Refusing to stop schema-4 OpenCode broker: " .. (stop_err or "unknown error"), vim.log.levels.ERROR)
          return
        end
        local removed, remove_err = test_hooks.remove_schema4_metadata_while_locked(state)
        release_lock()
        if not removed then
          notify(remove_err, vim.log.levels.ERROR)
          return
        end
        close_local_tui()
        notify("Stopped shared OpenCode broker and backend", vim.log.levels.INFO)
      end)
      return
    end
    local owned, ownership = process_is_owned(state)
    -- One dead TLS role must not prevent explicit cleanup of the separately
    -- verified survivor. stop_pair signals only identities that are still live.
    if not owned and state_transport(state) == "tls-proxy" then
      if not pid_is_live(state.proxy.pid) then
        owned, ownership = process_identity_is_owned(state.backend, state.boot_id)
      elseif not pid_is_live(state.backend.pid) then
        owned, ownership = process_identity_is_owned(state.proxy, state.boot_id)
      end
    end
    if not owned then
      local proxy_dead = state_transport(state) ~= "tls-proxy" or not pid_is_live(state.proxy.pid)
      if proxy_dead and not pid_is_live(state.backend.pid) then
        local removed, remove_err =
          remove_matching_state_while_locked(state.generation, "stopped generation state removal")
        if not removed then
          release_lock()
          notify(remove_err, vim.log.levels.ERROR)
          return
        end
        release_lock()
        close_local_tui()
        notify("Removed stale state for an already stopped shared OpenCode server", vim.log.levels.INFO)
        return
      end
      release_lock()
      notify("Refusing to stop shared OpenCode server: " .. ownership, vim.log.levels.ERROR)
      return
    end
    stop_pair(state, uv.hrtime() + stop_timeout_ms * 1000000, function(stopped, stop_err)
      if not stopped then
        release_lock()
        notify("Refusing to stop shared OpenCode server: " .. (stop_err or "unknown error"), vim.log.levels.ERROR)
        return
      end
      local removed, remove_err =
        remove_matching_state_while_locked(state.generation, "stopped generation state removal")
      release_lock()
      if not removed then
        notify(remove_err, vim.log.levels.ERROR)
        return
      end
      close_local_tui()
      notify(
        state_transport(state) == "tls-proxy" and "Stopped shared OpenCode proxy and backend"
          or "Stopped shared OpenCode direct backend",
        vim.log.levels.INFO
      )
    end)
  end)
end

local reload_waiters = {}
local reload_active = false

local function absolute_cwd()
  local cwd = vim.fn.getcwd()
  if cwd == "" then
    return nil
  end
  local absolute = vim.fn.fnamemodify(cwd, ":p")
  return absolute == "/" and absolute or absolute:gsub("/$", "")
end

local function contains_busy_status(value)
  if type(value) == "string" then
    return value == "busy"
  elseif type(value) == "table" then
    for _, child in pairs(value) do
      if contains_busy_status(child) then
        return true
      end
    end
  end
  return false
end

local function contains_pending_item(value)
  if type(value) ~= "table" then
    return value ~= nil and value ~= false
  end
  if #value > 0 then
    return true
  end
  for _, child in pairs(value) do
    if contains_pending_item(child) then
      return true
    end
  end
  return false
end

local function finish_reload(ok, message)
  local callbacks = reload_waiters
  reload_waiters = {}
  reload_active = false
  for _, callback in ipairs(callbacks) do
    callback(ok, message)
  end
end

local function reload_current_directory(callback)
  table.insert(reload_waiters, callback or function() end)
  if reload_active then
    return
  end
  reload_active = true

  local directory = absolute_cwd()
  if not directory then
    finish_reload(false, "Unable to determine the current Neovim directory for OpenCode reload")
    return
  end
  local initial_state = read_state()
  managed_state_if_healthy(initial_state, nil, function(healthy_state, detail)
    if not healthy_state then
      finish_reload(
        false,
        "OpenCode reload is inactive for "
          .. directory
          .. " ("
          .. (detail and detail.kind or "inactive")
          .. "); it did not start a server"
      )
      return
    end
    acquire_lock(function(locked, lock_err)
      if not locked then
        finish_reload(false, "OpenCode reload could not acquire the lifecycle lock: " .. (lock_err or "unknown error"))
        return
      end
      local function fail(phase, err)
        release_lock()
        finish_reload(
          false,
          "OpenCode reload failed during " .. phase .. " for " .. directory .. ": " .. (err or "unknown error")
        )
      end
      local function request(path, method, body, done)
        request_json(healthy_state, path, method, body, directory, function(result, request_detail)
          if result then
            done(result)
          else
            done(nil, request_detail.kind)
          end
        end)
      end
      local locked_state = read_state()
      managed_state_if_healthy(locked_state, nil, function(rechecked, recheck_detail)
        if not rechecked then
          fail("managed-state validation", recheck_detail and recheck_detail.kind)
          return
        end
        if
          state_transport(rechecked) ~= state_transport(healthy_state)
          or (state_transport(rechecked) == "tls-proxy" and rechecked.proxy.pid ~= healthy_state.proxy.pid)
          or rechecked.backend.pid ~= healthy_state.backend.pid
          or rechecked.generation ~= healthy_state.generation
          or rechecked.url ~= healthy_state.url
          or rechecked.certificate_identity ~= healthy_state.certificate_identity
        then
          fail("managed-state validation", "the shared server changed while reload was waiting")
          return
        end
        request("/session/status", "GET", nil, function(status, status_err)
          if not status then
            fail("session-status preflight", status_err)
          elseif contains_busy_status(status) then
            fail("session-status preflight", "current-directory work is active; reload was not attempted")
          else
            request("/permission", "GET", nil, function(permissions, permission_err)
              if not permissions then
                fail("permission preflight", permission_err)
              elseif contains_pending_item(permissions) then
                fail("permission preflight", "a current-directory permission is pending; reload was not attempted")
              else
                request("/question", "GET", nil, function(questions, question_err)
                  if not questions then
                    fail("question preflight", question_err)
                  elseif contains_pending_item(questions) then
                    fail("question preflight", "a current-directory question is pending; reload was not attempted")
                  else
                    local owns_lock, ownership_err = require_lock_ownership "instance disposal request"
                    if not owns_lock then
                      fail("instance disposal", ownership_err)
                      return
                    end
                    request("/instance/dispose", "POST", nil, function(_, dispose_err)
                      if dispose_err then
                        fail("instance disposal", dispose_err)
                        return
                      end
                      local connected = require("opencode.server").connected
                      if connected then
                        connected:disconnect()
                      end
                      close_local_tui()
                      request("/path", "GET", nil, function(path, path_err)
                        if not path then
                          fail("instance recreation", path_err)
                        elseif path.directory ~= directory then
                          fail(
                            "routed-path validation",
                            "server returned " .. vim.inspect(path.directory) .. " instead of " .. directory
                          )
                        else
                          -- TUI and plugin connection subprocesses are not lifecycle
                          -- mutations. Revalidate under a newly acquired fence after
                          -- they complete instead of holding exclusion while waiting.
                          release_lock()
                          local function fail_unlocked(phase, err)
                            finish_reload(
                              false,
                              "OpenCode reload failed during "
                                .. phase
                                .. " for "
                                .. directory
                                .. ": "
                                .. (err or "unknown error")
                            )
                          end
                          ensure_local_tui(rechecked, function(tui_ok, tui_err)
                            if not tui_ok then
                              fail_unlocked("local TUI recreation", tui_err)
                              return
                            end
                            local loaded, discovery = pcall(require, "opencode.server.discovery")
                            if not loaded then
                              fail_unlocked("plugin reconnection", discovery)
                              return
                            end
                            discovery
                              .get()
                              :next(function()
                                acquire_lock(function(final_locked, final_lock_err)
                                  if not final_locked then
                                    fail_unlocked("shared-server validation", final_lock_err)
                                    return
                                  end
                                  local final_state = read_state()
                                  if
                                    not final_state
                                    or state_transport(final_state) ~= state_transport(rechecked)
                                    or (state_transport(final_state) == "tls-proxy" and final_state.proxy.pid ~= rechecked.proxy.pid)
                                    or final_state.backend.pid ~= rechecked.backend.pid
                                    or final_state.generation ~= rechecked.generation
                                    or final_state.url ~= rechecked.url
                                    or final_state.port ~= rechecked.port
                                    or final_state.certificate_identity ~= rechecked.certificate_identity
                                  then
                                    fail("shared-server validation", "shared server state changed during reload")
                                    return
                                  end
                                  release_lock()
                                  finish_reload(
                                    true,
                                    "Reloaded OpenCode instance for "
                                      .. directory
                                      .. "; global process-cached configuration may still require shared stop/start"
                                  )
                                end)
                              end)
                              :catch(function(err)
                                fail_unlocked("plugin reconnection", tostring(err))
                              end)
                          end)
                        end
                      end)
                    end)
                  end
                end)
              end
            end)
          end
        end)
      end)
    end)
  end)
end

local function render_info(
  state,
  state_status,
  launch_intent,
  launch_status,
  configured,
  configured_err,
  url,
  executable,
  local_version
)
  local port_source = server_setting_source "OPENCODE_PORT"
    or (state and state.port_source)
    or "preferred 4096 on first use"
  local lines = {
    "State directory: " .. paths().root,
    "Server config: " .. server_config_path,
    "State status: " .. state_status,
    "Launch intent: "
      .. (
        launch_intent
          and (launch_intent.role .. "; generation " .. launch_intent.generation .. (launch_intent.pid and ("; PID " .. launch_intent.pid) or "; PID unavailable"))
        or launch_status
      ),
    "Requested transport: " .. requested_transport(),
    "Active transport: " .. (state_transport(state) or "inactive"),
    "URL: " .. (url or "inactive"),
    "Port source: " .. port_source,
    "Local version: " .. (executable and local_version or "unavailable"),
    "Neovim cwd: " .. vim.fn.getcwd(),
    "Plugin SSE: " .. (require("opencode.server").connected and "connected" or "disconnected"),
    "Local TUI: "
      .. (
        tui_valid()
          and ("valid; " .. local_tui.url .. "; " .. local_tui.directory .. "; generation " .. local_tui.generation)
        or "absent"
      ),
    "TUI API presence: unknown/unsupported",
    "CA certificate: "
      .. (
        state_transport(state) == "tls-proxy" and state.ca_path
        or "inactive; retained material may exist at " .. paths().ca
      ),
    "Backend log: " .. (state and state.backend and state.backend.log or paths().log),
    "Proxy log: "
      .. (
        state_transport(state) == "tls-proxy" and state.proxy.log or "inactive; retained log at " .. paths().proxy_log
      ),
    "Client authentication: "
      .. (
        (vim.env.OPENCODE_SERVER_PASSWORD and vim.env.OPENCODE_SERVER_PASSWORD ~= "")
          and ("OpenCode Basic Auth password is configured by " .. (server_setting_source "OPENCODE_SERVER_PASSWORD" or "the process environment"))
        or no_password_warning()
      ),
  }
  if configured_err then
    table.insert(lines, "Port error: " .. configured_err)
  end
  local active_transport = state_transport(state)
  if active_transport and active_transport ~= requested_transport() then
    table.insert(
      lines,
      "Mode mismatch: requested "
        .. requested_transport()
        .. ", active "
        .. active_transport
        .. "; run :OpenCodeStop, restart Neovim, and start OpenCode again"
    )
  end
  if state then
    local owned, ownership = process_is_owned(state)
    if state.schema == 1 then
      vim.list_extend(lines, {
        "Legacy PID: " .. state.pid .. " (" .. ownership .. ")",
        "Generation: " .. state.generation,
        "Security: legacy schema 1 HTTP is never probed or sent credentials",
      })
    else
      vim.list_extend(lines, {
        "Proxy PID: " .. (state_transport(state) == "tls-proxy" and state.proxy.pid or "inactive"),
        "Backend PID: " .. state.backend.pid,
        "Backend port: " .. state.backend.port,
        "Pair identity: " .. ownership,
        "Generation: " .. state.generation,
        "Certificate identity: " .. (state.certificate_identity or "inactive"),
        "Started: " .. state.started_at,
      })
    end
    if not owned then
      table.insert(lines, "PID warning: state must not be used to signal this process")
    end
  end
  if not state or (state.schema ~= 2 and state.schema ~= 3 and state.schema ~= 4) then
    table.insert(
      lines,
      "Managed endpoint: " .. (state_status == "legacy" and "legacy state blocked" or "inactive/untrusted")
    )
    notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return
  end
  local authenticated = state.url == url
      and process_is_owned(state)
      and process_listens_on_port(state.backend.pid, state.backend.port)
      and (state_transport(state) ~= "tls-proxy" or process_listens_on_port(state.proxy.pid, state.port))
    or false
  if not authenticated then
    table.insert(lines, "Managed endpoint: ownership or listener validation failed; no request sent")
    notify(table.concat(lines, "\n"), vim.log.levels.WARN)
    return
  end
  if
    state_transport(state) == "tls-proxy"
    and (state.ca_path ~= paths().ca or certificate_identity(paths()) ~= state.certificate_identity)
  then
    table.insert(lines, "Managed endpoint: certificate identity validation failed; no request sent")
    notify(table.concat(lines, "\n"), vim.log.levels.WARN)
    return
  end
  probe_health(state, function(health, detail)
    table.insert(lines, (state_transport(state) == "tls-proxy" and "HTTPS" or "HTTP") .. " endpoint: " .. detail.kind)
    table.insert(lines, "Health latency: " .. detail.latency_ms .. "ms")
    if health then
      table.insert(lines, "Server version: " .. (health.version or "unknown"))
      if
        state.backend.local_version ~= "unknown"
        and health.version
        and state.backend.local_version ~= health.version
      then
        table.insert(
          lines,
          "Version warning: stop the shared server and use OpenCode again to launch the updated executable"
        )
      end
    end
    notify(table.concat(lines, "\n"), health and vim.log.levels.INFO or vim.log.levels.WARN)
  end, authenticated)
end

local function show_info()
  if vim.g.mkchad_opencode_test_api and not vim.g.mkchad_opencode_test_command_argv then
    local state, state_status = read_state()
    local launch_intent, launch_status = read_launch_intent()
    local configured, configured_err = explicit_port()
    local scheme = requested_transport() == "tls-proxy" and "https" or "http"
    local url = state and state.url or (configured and ("%s://%s:%d"):format(scheme, host, configured))
    resolve_executable(uv.hrtime() + subprocess_timeout_ms * 1000000, function(executable, local_version)
      render_info(
        state,
        state_status,
        launch_intent,
        launch_status,
        configured,
        configured_err,
        url,
        executable,
        local_version
      )
    end)
    return
  end
  command_adapter.status(function(status, state, command_err)
    local server = package.loaded["opencode.server"]
    local lines = {
      "Command status: " .. status,
      "URL: " .. (state and state.url or "inactive"),
      "Transport: " .. (state and state.transport or "inactive"),
      "Generation: " .. (state and state.generation or "inactive"),
      "Server version: " .. (state and state.server_version or "unknown"),
      "Plugin SSE: " .. (server and server.connected and "connected" or "disconnected"),
      "Local TUI: "
        .. (
          tui_valid()
            and ("valid; " .. local_tui.url .. "; " .. local_tui.directory .. "; generation " .. local_tui.generation)
          or "absent"
        ),
    }
    if state and state.transport == "tls-proxy" then
      table.insert(lines, "CA certificate: " .. state.ca_cert)
    end
    if command_err then
      table.insert(lines, "Command diagnostic: " .. command_err)
    end
    notify(
      table.concat(lines, "\n"),
      (status == "healthy" or status == "inactive") and vim.log.levels.INFO or vim.log.levels.WARN
    )
  end)
end

-- These lifecycle-only operations are deliberately independent of the editor
-- presentation layer.  The standalone entrypoint uses them from a fresh
-- headless Neovim process; the normal adapter continues to own notifications
-- and the attached terminal.
local function ensure_server(callback)
  local loaded, config_err = load_server_config()
  if not loaded then
    callback(false, "OpenCode server configuration " .. (config_err or "is invalid"))
    return
  end
  ensure_backend(callback, false)
end

local function observe_server(callback)
  local loaded, config_err = load_server_config()
  if not loaded then
    callback("blocked", nil, "OpenCode server configuration " .. (config_err or "is invalid"), "configuration_invalid")
    return
  end
  local state, state_status = read_state()
  if not state then
    local pending, pending_status = read_pending()
    if pending and pending.schema == 4 then
      test_hooks.observe_broker(pending, function(receipt, receipt_err)
        if not receipt then
          callback("blocked", nil, receipt_err or "broker-control-unavailable", "broker_control_unavailable")
        elseif receipt.phase == "blocked" then
          callback("blocked", nil, "broker-blocked-pending", "broker_blocked")
        elseif receipt.phase == "stopping" then
          callback("stopping", nil, "broker-stopping-pending", "broker_stopping")
        elseif receipt.phase == "running" and test_hooks.broker_receipt_matches_backend(receipt, pending.backend) then
          callback("unhealthy", nil, "broker-running-pending", "broker_running_pending")
        else
          callback(
            "unhealthy",
            nil,
            "broker-" .. receipt.phase .. "-pending",
            "broker_" .. receipt.phase:gsub("-", "_")
          )
        end
      end)
      return
    end
    local intent, intent_status = read_launch_intent()
    if intent and intent.schema == 2 then
      callback("blocked", nil, "broker-starting", "broker_starting")
      return
    end
    if pending_status == "malformed" or intent_status == "malformed" then
      callback("blocked", nil, "lifecycle authority metadata is malformed", "authority_metadata_malformed")
      return
    end
    callback(state_status == "missing" and "inactive" or "blocked", nil, state_status)
    return
  end
  if state.schema == 1 then
    callback("blocked", nil, "schema 1 state is legacy and is never probed", "legacy_state")
    return
  end
  managed_state_if_healthy(state, nil, function(healthy, detail)
    if healthy then
      callback("healthy", healthy)
      return
    end
    local message = detail and (detail.message or detail.kind) or "unknown state validation failure"
    local unhealthy = detail
      and (
        detail.kind == "owned-unhealthy"
        or detail.kind == "schema4-broker-live-backend-dead"
        or detail.kind == "schema4-both-dead"
      )
    callback(
      detail and detail.kind == "stopping" and "stopping" or unhealthy and "unhealthy" or "blocked",
      nil,
      message,
      detail and detail.kind and detail.kind:gsub("-", "_") or nil
    )
  end)
end

function test_hooks.reset_record_roles(record)
  local roles = {}
  if record and record.schema == 1 and record.pid then
    table.insert(roles, { name = "legacy server", process = { pid = record.pid } })
  end
  if record and record.proxy then
    table.insert(roles, { name = record.schema == 4 and "broker" or "proxy", process = record.proxy })
  end
  if record and record.backend then
    table.insert(roles, { name = "backend", process = record.backend })
  end
  return roles
end

function test_hooks.valid_record_live_role(record)
  for _, role in ipairs(test_hooks.reset_record_roles(record)) do
    if pid_is_live(role.process.pid) then
      return role.name
    end
  end
end

function test_hooks.launch_intent_live_role(intent)
  local pid = intent and intent.schema == 2 and intent.proxy.pid or intent and intent.pid
  if pid and pid_is_live(pid) then
    return intent.schema == 2 and "broker launch" or (intent.role .. " launch")
  end
end

function test_hooks.recorded_roles_are_absent(record)
  local live_role = test_hooks.valid_record_live_role(record)
  if live_role then
    return nil, "recorded " .. live_role .. " remains live"
  end
  if record and record.schema == 4 and uv.fs_lstat(record.broker.control_path) then
    return nil, "recorded broker control authority remains present"
  end
  return true
end

function test_hooks.reset_file_is_safe(path)
  local entry = uv.fs_lstat(path)
  if entry and entry.type == "directory" then
    return nil, "reset artifact is unexpectedly a directory: " .. path
  end
  return true
end

function test_hooks.unlink_reset_file(path)
  local removed, remove_err = uv.fs_unlink(path)
  if removed or (remove_err and tostring(remove_err):find("ENOENT", 1, true)) then
    return true
  end
  return nil, remove_err or ("unable to remove reset artifact: " .. path)
end

-- Lifecycle-owned directories are flat. Preflight every child so reset never
-- follows a substituted symlink or enters an unexpected nested tree.
function test_hooks.preflight_flat_reset_directory(path)
  local entry = uv.fs_lstat(path)
  if not entry then
    return { path = path, entries = {} }
  end
  if entry.type ~= "directory" then
    return { path = path, entries = {} }
  end
  local scanner, scan_err = uv.fs_scandir(path)
  if not scanner then
    return nil, scan_err or ("unable to scan reset directory: " .. path)
  end
  local entries = {}
  while true do
    local name = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    local child = vim.fs.joinpath(path, name)
    local child_entry = uv.fs_lstat(child)
    if not child_entry or child_entry.type == "directory" then
      return nil, "reset directory contains an unsafe nested entry: " .. child
    end
    table.insert(entries, child)
  end
  return { path = path, entries = entries, directory = path }
end

function test_hooks.remove_preflighted_reset_directory(artifact)
  if not artifact.directory then
    return test_hooks.unlink_reset_file(artifact.path)
  end
  for _, child in ipairs(artifact.entries) do
    local removed, remove_err = test_hooks.unlink_reset_file(child)
    if not removed then
      return nil, remove_err
    end
  end
  local removed, remove_err = uv.fs_rmdir(artifact.directory)
  return removed or nil, remove_err or ("unable to remove reset directory: " .. artifact.directory)
end

function test_hooks.reset_lifecycle_artifacts_while_locked()
  local owned, ownership_err = require_lock_ownership "lifecycle reset"
  if not owned then
    return nil, ownership_err
  end
  local root_identity, root_err = test_hooks.read_authority_root()
  if not root_identity or not authority_root_is_stable(root_identity) then
    return nil, root_err or "OpenCode authority root changed during lifecycle reset"
  end
  local state_paths = paths()
  local files = {
    state_paths.state,
    state_paths.pending,
    state_paths.launch,
    state_paths.control,
    state_paths.control_quarantine,
    state_paths.log,
    state_paths.proxy_log,
  }
  for _, path in ipairs(files) do
    local safe, safe_err = test_hooks.reset_file_is_safe(path)
    if not safe then
      return nil, safe_err
    end
  end

  local directories = { state_paths.tls }
  local scanner, scan_err = uv.fs_scandir(state_paths.root)
  if not scanner then
    return nil, scan_err or "unable to scan lifecycle root for stale lifecycle debris"
  end
  while true do
    local name = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    if
      name:match "^startup%.lock%.stale%-.+$"
      or name:match "^startup%.lock%.release%-.+$"
      or name:match "^startup%.lock%.unpublished%-.+$"
      or name:match "^state%.json%..+%.tmp$"
      or name:match "^pending%.json%..+%.tmp$"
      or name:match "^launch%.json%..+%.tmp$"
      or name:match "^%.lease%-.+%.tmp$"
      or name:match "^tls%.new%-.+$"
      or name:match "^tls%.invalid%-.+$"
    then
      table.insert(directories, vim.fs.joinpath(state_paths.root, name))
    end
  end

  local preflighted = {}
  for _, path in ipairs(directories) do
    local artifact, preflight_err = test_hooks.preflight_flat_reset_directory(path)
    if not artifact then
      return nil, preflight_err
    end
    table.insert(preflighted, artifact)
  end
  for _, artifact in ipairs(preflighted) do
    local removed, remove_err = test_hooks.remove_preflighted_reset_directory(artifact)
    if not removed then
      return nil, remove_err
    end
  end
  -- Remove authority metadata last so a preflight or debris-cleanup refusal
  -- retains the evidence needed for manual process accounting.
  for index = #files, 1, -1 do
    local removed, remove_err = test_hooks.unlink_reset_file(files[index])
    if not removed then
      return nil, remove_err
    end
  end
  return true
end

function test_hooks.clear_server(callback)
  acquire_lock(function(locked, lock_err)
    if not locked then
      callback(false, lock_err)
      return
    end
    local state, state_status = read_state()
    local pending, pending_status = read_pending()
    local intent, intent_status = read_launch_intent()
    if not state and state_status ~= "missing" and state_status ~= "malformed" then
      release_lock()
      callback(false, "Refusing lifecycle reset: lifecycle state is " .. state_status)
      return
    end
    if not pending and pending_status and pending_status ~= "malformed" then
      release_lock()
      callback(false, "Refusing lifecycle reset: pending lifecycle state is " .. pending_status)
      return
    end
    if not intent and intent_status ~= "missing" and intent_status ~= "malformed" then
      release_lock()
      callback(false, "Refusing lifecycle reset: launch intent is " .. intent_status)
      return
    end
    for _, record in pairs { state = state, pending = pending } do
      local live_role = test_hooks.valid_record_live_role(record)
      if live_role then
        release_lock()
        callback(false, "Refusing lifecycle reset: validated managed " .. live_role .. " remains live")
        return
      end
    end
    local live_intent_role = test_hooks.launch_intent_live_role(intent)
    if live_intent_role then
      release_lock()
      callback(false, "Refusing lifecycle reset: validated managed " .. live_intent_role .. " remains live")
      return
    end
    local reset, reset_err = test_hooks.reset_lifecycle_artifacts_while_locked()
    release_lock()
    callback(reset and true or false, reset_err)
  end)
end

function test_hooks.stop_record_for_kill(record, deadline_ns, callback)
  if not record then
    callback(true)
    return
  end
  if record.schema == 1 then
    stop_legacy(record, deadline_ns, callback)
    return
  end
  if record.schema == 4 then
    if not pid_is_live(record.proxy.pid) and (not record.backend or not pid_is_live(record.backend.pid)) then
      local reclaimed, reclaim_err = test_hooks.reclaim_dead_schema4_control_while_locked(record)
      callback(reclaimed and true or false, reclaim_err)
      return
    end
    test_hooks.stop_schema4(record, deadline_ns, callback)
    return
  end
  local owned, ownership = process_is_owned(record)
  if owned then
    stop_pair(record, deadline_ns, callback)
    return
  end
  local live_roles = {}
  for _, role in ipairs(test_hooks.reset_record_roles(record)) do
    if pid_is_live(role.process.pid) then
      table.insert(live_roles, role)
    end
  end
  if #live_roles == 0 then
    callback(true)
  elseif #live_roles == 1 then
    local live_role = live_roles[1]
    local verified, verify_err = process_identity_is_owned(live_role.process, record.boot_id)
    if verified then
      stop_pair(record, deadline_ns, callback)
    else
      callback(false, "recorded " .. live_role.name .. " is live but unverifiable: " .. (verify_err or ownership))
    end
  else
    callback(
      false,
      "recorded managed roles are live but their joint identity is unverifiable: " .. (ownership or "unknown error")
    )
  end
end

function test_hooks.kill_server(callback)
  local deadline_ns = uv.hrtime() + startup_timeout_ms * 1000000
  acquire_lock(function(locked, lock_err)
    if not locked then
      callback(false, lock_err)
      return
    end
    local function fail(message)
      release_lock()
      callback(false, message)
    end
    local state, state_status = read_state()
    local pending, pending_status = read_pending()
    local intent, intent_status = read_launch_intent()
    if not state and state_status ~= "missing" then
      fail("Lifecycle state is " .. state_status .. "; use clear only after manual process accounting")
      return
    end
    if not pending and pending_status then
      fail("Pending lifecycle state is " .. pending_status .. "; use clear only after manual process accounting")
      return
    end
    if not intent and intent_status ~= "missing" then
      fail("Launch intent is " .. intent_status .. "; use clear only after manual process accounting")
      return
    end
    if intent and not launch_intent_is_covered(intent, pending) then
      local intent_pid = intent.schema == 2 and intent.proxy.pid or intent.pid
      if not intent_pid then
        fail "Uncovered launch intent has no PID authority; use clear only after manual process accounting"
        return
      end
      local live_intent_role = test_hooks.launch_intent_live_role(intent)
      if live_intent_role then
        fail("Recorded " .. live_intent_role .. " remains live without signal authority")
        return
      end
    end
    test_hooks.stop_record_for_kill(state, deadline_ns, function(stopped, stop_err)
      if not stopped then
        fail("Validated lifecycle shutdown failed: " .. (stop_err or "unknown error"))
        return
      end
      if
        pending
        and pending.schema == 4
        and not pid_is_live(pending.proxy.pid)
        and (not pending.backend or not pid_is_live(pending.backend.pid))
      then
        local reclaimed, reclaim_err = test_hooks.reclaim_dead_schema4_control_while_locked(pending)
        if not reclaimed then
          fail("Validated pending control cleanup failed: " .. (reclaim_err or "unknown error"))
          return
        end
      end
      cleanup_pending(deadline_ns, function(pending_stopped, pending_err)
        if not pending_stopped then
          fail("Validated pending lifecycle shutdown failed: " .. (pending_err or "unknown error"))
          return
        end
        local remaining_intent, remaining_intent_status = read_launch_intent()
        if not remaining_intent and remaining_intent_status ~= "missing" then
          fail "Launch intent changed or became malformed during validated shutdown"
          return
        end
        local remaining_intent_role = test_hooks.launch_intent_live_role(remaining_intent)
        if remaining_intent_role then
          fail("Recorded " .. remaining_intent_role .. " remains live without signal authority")
          return
        end
        local remaining_state, remaining_state_status = read_state()
        local remaining_pending, remaining_pending_status = read_pending()
        if not remaining_state and remaining_state_status ~= "missing" then
          fail "Lifecycle state changed or became malformed during validated shutdown"
          return
        end
        if not remaining_pending and remaining_pending_status then
          fail "Pending lifecycle state changed or became malformed during validated shutdown"
          return
        end
        for _, record in pairs { state = remaining_state, pending = remaining_pending } do
          local absent, absent_err = test_hooks.recorded_roles_are_absent(record)
          if not absent then
            fail("Lifecycle reset refused: " .. absent_err)
            return
          end
        end
        local reset, reset_err = test_hooks.reset_lifecycle_artifacts_while_locked()
        release_lock()
        callback(reset and true or false, reset_err)
      end)
    end)
  end)
end

local function stop_server(callback)
  if lifecycle_reporter then
    callback(false, "another lifecycle result is pending")
    return
  end
  lifecycle_reporter = function(message, level)
    callback(level ~= vim.log.levels.ERROR and level ~= vim.log.levels.WARN, message)
  end
  stop_shared_server()
end

local function move_terminal(position)
  if position ~= "default" and not terminal_sizes[position] then
    notify("Usage: :Opencode move " .. table.concat(terminal_positions, "|"), vim.log.levels.ERROR)
    return
  end
  terminal_position = position
  if tui_valid() then
    local_tui.term.opts = vim.tbl_deep_extend("force", local_tui.term.opts, terminal_opts(position).win)
    local_tui.term:hide()
    local_tui.term:show()
  end
  notify("Moved local OpenCode terminal to " .. position, vim.log.levels.INFO)
end

local function complete_opencode(arg_lead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  if words[2] == "move" and (cmdline:match "%s$" or #words >= 3) then
    return vim.tbl_filter(function(position)
      return vim.startswith(position, arg_lead)
    end, terminal_positions)
  end
  return vim.tbl_filter(function(action)
    return vim.startswith(action, arg_lead)
  end, { "ask", "info", "move", "reload", "select", "start", "stop", "toggle" })
end

local function run_opencode_command(opts)
  local action = opts.fargs[1] or ""
  if action == "" or action == "toggle" then
    show_local_tui(true)
  elseif action == "start" then
    show_local_tui(false)
  elseif action == "stop" then
    command_adapter.stop(function(stopped, stop_err)
      if stopped then
        close_local_tui()
        notify("Stopped shared OpenCode server", vim.log.levels.INFO)
      else
        notify(stop_err or "Unable to stop shared OpenCode server", vim.log.levels.ERROR)
      end
    end)
  elseif action == "info" then
    show_info()
  elseif action == "reload" then
    reload_current_directory(function(ok, message)
      notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  elseif action == "move" then
    move_terminal(opts.fargs[2] or "default")
  elseif action == "ask" then
    require("opencode").ask()
  elseif action == "select" then
    require("opencode").select()
  else
    require("opencode").command(table.concat(opts.fargs, " "))
  end
end

if not lifecycle_only then
  vim.g.opencode_opts = {
    server = {
      url = function(callback)
        if vim.g.mkchad_opencode_test_api and not vim.g.mkchad_opencode_test_command_argv then
          local state = read_state()
          callback(state and (state.schema == 2 or state.schema == 3) and state.url or nil)
        else
          callback(command_adapter.endpoint_cache and command_adapter.endpoint_cache.url or nil)
        end
      end,
      ensure = function(callback)
        if vim.g.mkchad_opencode_test_api and not vim.g.mkchad_opencode_test_command_argv then
          ensure_backend(callback)
        else
          command_adapter.ensure(callback)
        end
      end,
      ca_cert = function()
        if vim.g.mkchad_opencode_test_api and not vim.g.mkchad_opencode_test_command_argv then
          local state = read_state()
          return state and state_transport(state) == "tls-proxy" and state.ca_path or nil
        end
        return command_adapter.endpoint_cache
            and command_adapter.endpoint_cache.transport == "tls-proxy"
            and command_adapter.endpoint_cache.ca_cert
          or nil
      end,
      start = false,
    },
  }

  vim.api.nvim_create_user_command("Opencode", run_opencode_command, {
    complete = complete_opencode,
    desc = "Control the local OpenCode TUI and shared server",
    force = true,
    nargs = "*",
  })
  vim.api.nvim_create_user_command("OpenCodeStart", function()
    show_local_tui(false)
  end, { desc = "Start the shared OpenCode server and local TUI", force = true })
  vim.api.nvim_create_user_command("OpenCodeStop", function()
    command_adapter.stop(function(stopped, stop_err)
      if stopped then
        close_local_tui()
        notify("Stopped shared OpenCode server", vim.log.levels.INFO)
      else
        notify(stop_err or "Unable to stop shared OpenCode server", vim.log.levels.ERROR)
      end
    end)
  end, {
    desc = "Stop the shared OpenCode server and close the local TUI",
    force = true,
  })
  vim.api.nvim_create_user_command("OpenCodeInfo", show_info, {
    desc = "Show live OpenCode server information without starting it",
    force = true,
  })
  vim.api.nvim_create_user_command("OpenCodeReload", function()
    reload_current_directory(function(ok, message)
      notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  end, {
    desc = "Reload the current OpenCode directory instance without restarting the shared server",
    force = true,
  })
end

-- Narrow test seam for the headless lifecycle regression script. It is only
-- installed when explicitly requested before this configuration is sourced.
if vim.g.mkchad_opencode_test_api then
  vim.g.mkchad_opencode_test_api = {
    acquire_lock = acquire_lock,
    ensure_state_dir = ensure_state_dir,
    broker_exchange = broker_exchange,
    lock_is_owned = lock_is_owned,
    managed_state_if_healthy = managed_state_if_healthy,
    paths = paths,
    find_unique_listener_inode = find_unique_listener_inode,
    exact_lstat_inode = test_hooks.exact_lstat_inode,
    uint64_decimal = test_hooks.uint64_decimal,
    process_listens_on_port = process_listens_on_port,
    port_is_available = port_is_available,
    process_is_owned = process_is_owned,
    publish_lock_owner = publish_lock_owner,
    renew_lock = renew_lock,
    release_lock = release_lock,
    spawn_pair = spawn_pair,
    select_port = select_port,
    load_server_config = load_server_config,
    server_config_path = server_config_path,
    server_setting_source = server_setting_source,
    requested_transport = requested_transport,
    state_transport = state_transport,
    terminate_process = terminate_process,
    stop_pair = stop_pair,
    stop_legacy = stop_legacy,
    ensure_certificate_material = ensure_certificate_material,
    resolve_executable = resolve_executable,
    run_subprocess = run_subprocess,
    certificate_identity = certificate_identity,
    capture_process = capture_process,
    cleanup_pending = cleanup_pending,
    cleanup_failed_pair = cleanup_failed_pair,
    current_boot_id = current_boot_id,
    file_identity = file_identity,
    proc_start_time = proc_start_time,
    process_identity_is_owned = process_identity_is_owned,
    read_state = read_state,
    read_pending = read_pending,
    read_launch_intent = read_launch_intent,
    strict_json_objects = strict_json_objects,
    write_pending = write_pending,
    write_launch_intent = write_launch_intent,
    remove_matching_launch_intent = remove_matching_launch_intent,
    remove_matching_pending_while_locked = remove_matching_pending_while_locked,
    write_state = write_state_while_locked,
    remove_matching_state_while_locked = remove_matching_state_while_locked,
    fence_is_held = fence_is_held,
    set_test_hook = function(action, marker, resume)
      assert(
        vim.tbl_contains(
          { "pending_write", "pending_remove", "state_publish", "state_remove", "logical_reclaim", "signal" },
          action
        )
      )
      assert(absolute_path(marker) and absolute_path(resume))
      test_hooks[action] = { marker = marker, resume = resume }
    end,
    signal_process = signal_process,
    ensure_local_tui = ensure_local_tui,
    reload_current_directory = reload_current_directory,
    show_info = show_info,
    stop_shared_server = stop_shared_server,
    ensure_server = ensure_server,
    observe_server = observe_server,
    stop_server = stop_server,
    clear_server = test_hooks.clear_server,
    kill_server = test_hooks.kill_server,
    command_adapter_ensure = command_adapter.ensure,
    command_adapter_status = command_adapter.status,
    command_adapter_argv = command_adapter.argv,
    command_adapter_stop = command_adapter.stop,
    set_test_procfs_authority = function(available)
      assert(type(available) == "boolean")
      vim.g.mkchad_opencode_test_procfs_authority = available
      return true
    end,
    tui_valid = tui_valid,
  }
end

return {
  ensure = ensure_server,
  status = observe_server,
  stop = stop_server,
  clear = test_hooks.clear_server,
  kill = test_hooks.kill_server,
  paths = paths,
}

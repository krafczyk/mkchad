local config = assert(arg[1], "pass the MkChad config path")
local isolated_config_home = vim.fs.joinpath(vim.fn.stdpath("state"), "identity-config")
vim.env.XDG_CONFIG_HOME = isolated_config_home
local isolated_proxy_source = vim.fs.joinpath(vim.fn.stdpath("config"), "java", "MkChadTlsProxy.java")
assert(vim.fn.mkdir(vim.fs.dirname(isolated_proxy_source), "p", 448) ~= 0 or vim.uv.fs_stat(vim.fs.dirname(isolated_proxy_source)))
vim.fn.writefile({ "final class MkChadTlsProxy {}" }, isolated_proxy_source)
vim.g.mkchad_opencode_test_api = true
vim.g.mkchad_opencode_test_proxy_source = isolated_proxy_source
dofile(config)
local lifecycle = vim.g.mkchad_opencode_test_api
local paths = lifecycle.paths()
assert(vim.fn.mkdir(paths.root, "p", 448) ~= 0 or vim.uv.fs_stat(paths.root))

local source = assert(vim.fn.exepath("sleep") ~= "" and vim.fn.exepath("sleep"))
local executable = vim.fs.joinpath(paths.root, "copied-sleep")
local replacement = vim.fs.joinpath(paths.root, "replacement-sleep")
assert(vim.uv.fs_copyfile(source, executable))
assert(vim.uv.fs_chmod(executable, 493))
local launch_stat = assert(lifecycle.file_identity(executable))

local first_job = vim.fn.jobstart({ executable, "30" })
local first_pid = vim.fn.jobpid(first_job)
assert(first_pid > 0)
assert(vim.wait(1000, function()
  return lifecycle.proc_start_time(first_pid) ~= nil
end, 10))
local first, capture_err = lifecycle.capture_process(first_pid, {
  port = 55001,
  executable = executable,
  executable_dev = launch_stat.dev,
  executable_ino = launch_stat.ino,
  local_version = "identity-test",
  log = paths.log,
})
assert(first, capture_err)
assert(lifecycle.process_identity_is_owned(first, lifecycle.current_boot_id()))

assert(vim.uv.fs_copyfile(source, replacement))
assert(vim.uv.fs_chmod(replacement, 493))
assert(vim.uv.fs_rename(replacement, executable))
local deleted_link = assert(vim.uv.fs_readlink("/proc/" .. first_pid .. "/exe"))
assert(deleted_link:sub(-10) == " (deleted)", "atomic replacement did not produce a deleted executable link")
assert(lifecycle.process_identity_is_owned(first, lifecycle.current_boot_id()), "atomic replacement invalidated the original process")

local second_stat = assert(lifecycle.file_identity(executable))
local second_job = vim.fn.jobstart({ executable, "30" })
local second_pid = vim.fn.jobpid(second_job)
assert(second_pid > 0 and second_pid ~= first_pid)
assert(vim.wait(1000, function()
  return lifecycle.proc_start_time(second_pid) ~= nil
end, 10))
local second = assert(lifecycle.capture_process(second_pid, {
  port = 55001,
  executable = executable,
  executable_dev = second_stat.dev,
  executable_ino = second_stat.ino,
  local_version = "identity-test",
  log = paths.log,
}))
local wrong_inode = vim.deepcopy(second)
wrong_inode.process_executable_dev = first.process_executable_dev
wrong_inode.process_executable_ino = first.process_executable_ino
local unrelated_owned = lifecycle.process_identity_is_owned(wrong_inode, lifecycle.current_boot_id())
assert(not unrelated_owned, "same argv with another executable inode was accepted")

local function await(invoke, timeout)
  local done, values = false, nil
  invoke(function(...)
    done, values = true, { ... }
  end)
  assert(vim.wait(timeout or 5000, function()
    return done
  end, 10), "operation timed out")
  return unpack(values)
end

local locked, lock_err = await(lifecycle.acquire_lock, 3000)
assert(locked, lock_err)
local stopped, stop_err = await(function(done)
  lifecycle.terminate_process(first, lifecycle.current_boot_id(), vim.uv.hrtime() + 3000000000, done)
end, 5000)
lifecycle.release_lock()
assert(stopped, stop_err)
assert(vim.fn.jobwait({ first_job }, 1000)[1] ~= -1, "verified original process survived stop")
assert(vim.fn.jobwait({ second_job }, 0)[1] == -1, "stop signaled the unrelated replacement process")

local python = assert(vim.fn.exepath("python3") ~= "" and vim.fn.exepath("python3"))
local launcher = vim.fs.joinpath(paths.root, "interpreted-launcher")
local launcher_replacement = vim.fs.joinpath(paths.root, "interpreted-launcher.new")
local script = { "#!" .. python, "import time", "time.sleep(30)" }
vim.fn.writefile(script, launcher)
assert(vim.uv.fs_chmod(launcher, 493))
local original_launcher_stat = assert(lifecycle.file_identity(launcher))
local interpreted_job = vim.fn.jobstart({ launcher })
local interpreted_pid = vim.fn.jobpid(interpreted_job)
assert(interpreted_pid > 0)
assert(vim.wait(1000, function()
  return lifecycle.proc_start_time(interpreted_pid) ~= nil
end, 10))
local interpreted = assert(lifecycle.capture_process(interpreted_pid, {
  port = 55002,
  executable = launcher,
  executable_dev = original_launcher_stat.dev,
  executable_ino = original_launcher_stat.ino,
  local_version = "identity-test",
  log = paths.log,
}))
assert(
  interpreted.process_executable_dev ~= interpreted.executable_dev or interpreted.process_executable_ino ~= interpreted.executable_ino,
  "interpreted test process did not use a distinct runtime executable"
)
assert(lifecycle.process_identity_is_owned(interpreted, lifecycle.current_boot_id()), "original interpreted process was not verified")

vim.fn.writefile(script, launcher_replacement)
assert(vim.uv.fs_chmod(launcher_replacement, 493))
assert(vim.uv.fs_rename(launcher_replacement, launcher))
assert(not lifecycle.process_identity_is_owned(interpreted, lifecycle.current_boot_id()), "replaced interpreted launcher remained trusted")

locked, lock_err = await(lifecycle.acquire_lock, 3000)
assert(locked, lock_err)
stopped, stop_err = await(function(done)
  lifecycle.terminate_process(interpreted, lifecycle.current_boot_id(), vim.uv.hrtime() + 1000000000, done)
end, 3000)
lifecycle.release_lock()
assert(not stopped and stop_err:find("launch executable identity", 1, true), stop_err)
assert(vim.fn.jobwait({ interpreted_job }, 0)[1] == -1, "unverifiable interpreted process was signaled")

local replacement_launcher_stat = assert(lifecycle.file_identity(launcher))
local replacement_job = vim.fn.jobstart({ launcher })
local replacement_pid = vim.fn.jobpid(replacement_job)
assert(replacement_pid > 0 and replacement_pid ~= interpreted_pid)
assert(vim.wait(1000, function()
  return lifecycle.proc_start_time(replacement_pid) ~= nil
end, 10))
local interpreted_replacement = assert(lifecycle.capture_process(replacement_pid, {
  port = 55002,
  executable = launcher,
  executable_dev = replacement_launcher_stat.dev,
  executable_ino = replacement_launcher_stat.ino,
  local_version = "identity-test",
  log = paths.log,
}))
assert(vim.deep_equal(interpreted.argv, interpreted_replacement.argv), "replacement interpreted process did not preserve argv")
assert(
  interpreted.process_executable_dev == interpreted_replacement.process_executable_dev
    and interpreted.process_executable_ino == interpreted_replacement.process_executable_ino,
  "replacement interpreted process did not preserve the runtime executable"
)
local stale_launch = vim.deepcopy(interpreted_replacement)
stale_launch.executable_dev = original_launcher_stat.dev
stale_launch.executable_ino = original_launcher_stat.ino
assert(not lifecycle.process_identity_is_owned(stale_launch, lifecycle.current_boot_id()), "same-argv interpreted replacement inode was accepted")

local source_stat = assert(lifecycle.file_identity(paths.proxy_source))
local proxy_record = assert(lifecycle.capture_process(second_pid, {
  port = 55003,
  executable = executable,
  executable_dev = second_stat.dev,
  executable_ino = second_stat.ino,
  source = paths.proxy_source,
  source_dev = source_stat.dev,
  source_ino = source_stat.ino,
  log = paths.proxy_log,
}))
assert(lifecycle.process_identity_is_owned(proxy_record, lifecycle.current_boot_id()), "original Java source identity was not verified")
local source_replacement = paths.proxy_source .. ".new"
vim.fn.writefile({ "final class MkChadTlsProxy { int replacement; }" }, source_replacement)
assert(vim.uv.fs_rename(source_replacement, paths.proxy_source))
assert(not lifecycle.process_identity_is_owned(proxy_record, lifecycle.current_boot_id()), "replaced Java source remained trusted")
assert(
  lifecycle.process_identity_is_owned(proxy_record, lifecycle.current_boot_id(), true),
  "explicit broker replacement could not retain process identity after a source upgrade"
)

locked, lock_err = await(lifecycle.acquire_lock, 3000)
assert(locked, lock_err)
stopped, stop_err = await(function(done)
  lifecycle.terminate_process(proxy_record, lifecycle.current_boot_id(), vim.uv.hrtime() + 1000000000, done)
end, 3000)
lifecycle.release_lock()
assert(not stopped and stop_err:find("Java proxy source identity", 1, true), stop_err)
assert(vim.fn.jobwait({ second_job }, 0)[1] == -1, "proxy with unverifiable source was signaled")

locked, lock_err = await(lifecycle.acquire_lock, 3000)
assert(locked, lock_err)
stopped, stop_err = await(function(done)
  lifecycle.terminate_process(
    proxy_record,
    lifecycle.current_boot_id(),
    vim.uv.hrtime() + 3000000000,
    done,
    true
  )
end, 5000)
lifecycle.release_lock()
assert(stopped, stop_err)
assert(vim.fn.jobwait({ second_job }, 1000)[1] ~= -1, "explicit broker replacement retained the old process")

for _, job in ipairs({ second_job, interpreted_job, replacement_job }) do
  if vim.fn.jobwait({ job }, 0)[1] == -1 then
    vim.fn.jobstop(job)
    vim.fn.jobwait({ job }, 1000)
  end
end
vim.uv.fs_unlink(executable)
vim.uv.fs_unlink(launcher)
vim.cmd("qa!")

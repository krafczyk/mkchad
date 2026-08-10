local source = debug.getinfo(1, "S").source:gsub("^@", "")

if arg[1] == "driver" then
  local init, expected_root, expect_prefix = assert(arg[2]), arg[3], arg[4]
  vim.env.MSK_NPM_GLOBAL_ROOT = nil
  vim.env.NPM_CONFIG_PREFIX = nil

  dofile(init)

  assert(vim.env.MSK_NPM_GLOBAL_ROOT == (expected_root ~= "-" and expected_root or nil))
  assert(vim.env.NPM_CONFIG_PREFIX == (expected_root ~= "-" and expected_root or nil))
  if expect_prefix ~= "-" then
    assert(vim.env.PATH:sub(1, #expect_prefix + 1) == expect_prefix .. ":")
  end
  return
end

local init = assert(arg[1], "pass the MkChad mkinit.lua path")
local scratch_root = assert(vim.env.MKCHAD_TEST_ROOT, "MKCHAD_TEST_ROOT is required")
assert(scratch_root:match("^/tmp/mkchad%-v1/[^/]+$"), "MKCHAD_TEST_ROOT must be a direct child of /tmp/mkchad-v1")
local root = scratch_root .. "/mkinit-npm-prefix-" .. vim.fn.getpid()
local fake_bin = root .. "/fake-bin"

assert(vim.fn.mkdir(fake_bin, "p", 448) ~= 0 or vim.uv.fs_stat(fake_bin))
vim.fn.writefile({
  "#!/bin/bash",
  "[[ ${1:-} == -p ]] || exit 64",
  "printf '%s\\n' \"${MKCHAD_TEST_NODE_KEY:?}\"",
}, fake_bin .. "/node")
assert(vim.uv.fs_chmod(fake_bin .. "/node", 493))

local function run_case(name, env, expected_root, expected_prefix)
  local case_root = root .. "/" .. name
  local result = vim.system({
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-l",
    source,
    "driver",
    init,
    expected_root,
    expected_prefix,
  }, {
    env = vim.tbl_extend("force", {
      HOME = case_root .. "/home",
      XDG_CACHE_HOME = case_root .. "/cache",
      XDG_CONFIG_HOME = case_root .. "/config",
      XDG_DATA_HOME = case_root .. "/data",
      XDG_STATE_HOME = case_root .. "/state",
    }, env),
    text = true,
  }):wait()
  assert(result.code == 0, name .. ": " .. result.stderr)
end

local key = "linux-x64-node24"
local base = root .. "/npm-global"
run_case("neutral-base", {
  PATH = fake_bin,
  MKCHAD_TEST_NODE_KEY = key,
  MSK_NPM_GLOBAL_BASE = base,
}, base .. "/" .. key, base .. "/" .. key .. "/bin")
run_case("preselected-child", {
  PATH = fake_bin,
  MKCHAD_TEST_NODE_KEY = key,
  MSK_NPM_GLOBAL_BASE = base .. "/" .. key,
}, base .. "/" .. key, base .. "/" .. key .. "/bin")
run_case("node-absent", {
  PATH = root .. "/without-node",
  MSK_NPM_GLOBAL_BASE = base,
}, "-", "-")

vim.fn.delete(root, "rf")
print "mkinit npm prefix tests passed"

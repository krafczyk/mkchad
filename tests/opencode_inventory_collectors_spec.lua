local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = vim.fs.joinpath(root, "lua", "?.lua") .. ";" .. package.path

local collectors = require "mkchad.opencode.inventory_collectors"
local inventory = require "mkchad.opencode.inventory"
local evidence = require "mkchad.opencode.inventory_evidence"
local encoded = vim.base64
  .encode(vim.json.encode {
    schema = 1,
    container_runtime = { state = "present", family = "apptainer", version = "1.3.0" },
    selected_image = { state = "absent" },
    persisted_instance = { state = "absent" },
  })
  :gsub("%+", "-")
  :gsub("/", "_")
  :gsub("=", "")
local host = assert(collectors.decode_host_evidence(encoded))
assert(host.container_runtime.version == "1.3.0")
assert(not collectors.decode_host_evidence "!", "malformed host transport was accepted")
assert(not collectors.decode_host_evidence(string.rep("a", 6145)), "oversized host transport was accepted")
local arbitrary_identity = vim.base64
  .encode(vim.json.encode {
    schema = 1,
    selected_image = { state = "present", identity_kind = "host-file-stat-v1", identity = "not-a-stat" },
  })
  :gsub("%+", "-")
  :gsub("/", "_")
  :gsub("=", "")
assert(not collectors.decode_host_evidence(arbitrary_identity), "arbitrary host identity was accepted")

local omitted = collectors.collect {}
assert(#omitted.components == 14 and #omitted.observations <= 48 and #omitted.relationships <= 32)
assert(omitted.complete == false)
local loaded = false
for _, observation in ipairs(omitted.observations) do
  loaded = loaded
    or (
      observation.component_id == "opencode-nvim"
      and observation.layer == "loaded"
      and observation.state == "unprovable"
    )
end
assert(loaded, "loaded plugin identity was inferred from installation")
local incomplete_observations = vim.deepcopy(omitted.observations)
table.remove(incomplete_observations, 1)
assert(
  not pcall(inventory.model, omitted.components, incomplete_observations, omitted.relationships, omitted.diagnostics),
  "model accepted missing fixed observation slot"
)
local malformed = collectors.collect { host_evidence = "bad=" }
local host_invalid = false
for _, item in ipairs(malformed.diagnostics) do
  host_invalid = host_invalid or item.code == "host_evidence_invalid"
end
assert(malformed.complete == false and host_invalid)

local synthetic = collectors.collect {
  config_root = root,
  probe_results = {
    mkchad_git = { code = 0, stdout = "0123456789abcdef0123456789abcdef01234567-dirty\n" },
    opencode_nvim_git = { missing = true },
    sprint_nvim_git = { missing = true },
    opencode = { code = 0, stdout = "1.18.3-mkchad.7\n", path = vim.fn.exepath "nvim" },
    sprint_loop = { missing = true },
    git = { code = 0, stdout = "git version 2.43.0\n" },
    python = { code = 0, stdout = "Python 3.12.3\n" },
    node = { code = 0, stdout = "v24.18.0\n" },
    curl = { timed_out = true },
  },
  lifecycle = {
    persisted_state = "present",
    persisted_version = "1.18.3-mkchad.7",
    running_state = "present",
    running_version = "1.18.3-mkchad.7",
  },
}
local by_id = {}
for _, item in ipairs(synthetic.observations) do
  by_id[item.id] = item
end
assert(by_id["mkchad:installed"].identity == "0123456789abcdef0123456789abcdef01234567")
assert(by_id["mkchad:installed"].dirty == true)
assert(by_id["opencode:selected"].version == "1.18.3-mkchad.7")
assert(by_id["prereq-curl:installed"].state == "timed_out")
assert(synthetic.summary.evaluations.unknown >= 1)

local fixture = vim.fs.joinpath(vim.fn.stdpath "state", "inventory-package-fixture-" .. vim.fn.getpid())
local npm_root = vim.fs.joinpath(fixture, "npm")
local package_root = vim.fs.joinpath(npm_root, "lib", "node_modules", "opencode-project-reload")
local runtime = vim.fs.joinpath(package_root, "dist", "tui.js")
assert(vim.fn.mkdir(vim.fs.dirname(runtime), "p", 448) ~= 0)
local runtime_bytes = "fixture runtime"
vim.fn.writefile({ runtime_bytes }, runtime, "b")
local package_owner = {
  schema = 1,
  component_id = "opencode-project-reload",
  component_version = "0.1.0",
  relationships = {},
  identity_profile = {
    id = "opencode-project-reload-tui-v1",
    sha256 = vim.fn.sha256(runtime_bytes),
    included_roots = { "dist/tui.js" },
    exclusions = {},
    max_regular_files = 1,
    max_total_bytes = 1048576,
    max_per_file_bytes = 1048576,
    max_elapsed_ms = 1000,
    framing = "raw-file-bytes-v1",
  },
}
vim.fn.writefile({ vim.json.encode(package_owner) }, vim.fs.joinpath(package_root, "opencode-component.json"))
local package_model = collectors.collect { npm_root = npm_root }
local package_by_id = {}
for _, item in ipairs(package_model.observations) do
  package_by_id[item.id] = item
end
assert(package_by_id["opencode-project-reload:installed"].state == "present")
assert(package_by_id["opencode-project-reload:installed"].identity == vim.fn.sha256(runtime_bytes))
assert(vim.uv.fs_unlink(vim.fs.joinpath(package_root, "opencode-component.json")))
local missing_metadata = collectors.collect { npm_root = npm_root }
for _, item in ipairs(missing_metadata.observations) do
  if item.id == "opencode-project-reload:installed" then
    assert(item.state == "unavailable", "existing package without metadata was reported absent")
  end
end
local cache_home = vim.fs.joinpath(fixture, "cache-home")
local cache_package_root = vim.fs.joinpath(
  cache_home,
  "opencode",
  "packages",
  "opencode-project-reload@git+https:",
  "github.com",
  "example",
  "opencode-project-reload#fixture",
  "node_modules",
  "opencode-project-reload"
)
assert(vim.fn.mkdir(vim.fs.joinpath(cache_package_root, "dist"), "p", 448) ~= 0)
vim.fn.writefile({ runtime_bytes }, vim.fs.joinpath(cache_package_root, "dist", "tui.js"), "b")
vim.fn.writefile({ vim.json.encode(package_owner) }, vim.fs.joinpath(cache_package_root, "opencode-component.json"))
local cached_model = collectors.collect { cache_root = cache_home }
for _, item in ipairs(cached_model.observations) do
  if item.id == "opencode-project-reload:cached" then
    assert(item.state == "present" and item.identity == vim.fn.sha256(runtime_bytes), "versioned cache was not found")
  end
end
local unsafe_root = vim.fs.joinpath(fixture, "unsafe-tree")
assert(vim.fn.mkdir(vim.fs.joinpath(unsafe_root, "empty"), "p", 511) ~= 0)
assert(vim.uv.fs_chmod(vim.fs.joinpath(unsafe_root, "empty"), 511))
local unsafe_digest, unsafe_error = evidence.digest_profile(unsafe_root, {
  framing = "path-u32be-content-u64be-v1",
  exclusions = {},
  included_roots = { "empty" },
  max_regular_files = 1,
  max_total_bytes = 1,
  max_per_file_bytes = 1,
  max_elapsed_ms = 1000,
}, vim.uv.getuid(), vim.uv.hrtime() + 1000000000)
assert(not unsafe_digest and unsafe_error == "unsafe", "writable empty directory produced a trusted digest")
local fallback = collectors.fallback { persisted_state = "unavailable", running_state = "unavailable" }
assert(#fallback.components == 14 and fallback.complete == false)
assert(fallback.diagnostics[1].code == "collector_internal_error")

local pending = {}
local async_model
local finish_lifecycle = collectors.collect_async({
  config_root = root,
  executables = {
    opencode = false,
    sprint_loop = false,
    node = false,
    curl = false,
  },
  probe = function(argv, options, callback)
    assert(type(argv) == "table" and argv[1]:sub(1, 1) == "/")
    assert(options.replace_env and options.process_group and options.output_limit == 4096)
    assert(options.env.HOME == "/nonexistent" and options.cwd == "/")
    table.insert(pending, function()
      local name = vim.fs.basename(argv[1])
      callback { code = 0, stdout = name == "git" and "git version 2.43.0\n" or "Python 3.12.3\n" }
    end)
  end,
}, function(value)
  async_model = value
end)
finish_lifecycle { persisted_state = "absent", running_state = "unavailable" }
assert(async_model == nil, "collector completed before outstanding probes")
for _, complete in ipairs(pending) do
  complete()
end
assert(
  vim.wait(5000, function()
    return async_model ~= nil
  end, 10),
  "collector did not join lifecycle and probes"
)
assert(#async_model.components == 14)
local async_by_id = {}
for _, item in ipairs(async_model.observations) do
  async_by_id[item.id] = item
end
assert(async_by_id["prereq-git:installed"].version == "2.43.0", "async probe evidence was discarded")
assert(async_model.diagnostics[1] == nil or async_model.diagnostics[1].code ~= "collector_internal_error")

local synchronous_model
local finish_synchronous = collectors.collect_async({
  config_root = root,
  executables = { opencode = false, sprint_loop = false, node = false, curl = false },
  probe = function(argv, _, callback)
    local name = vim.fs.basename(argv[1])
    callback { code = 0, stdout = name == "git" and "git version 2.43.0\n" or "Python 3.12.3\n" }
  end,
}, function(value)
  synchronous_model = value
end)
finish_synchronous { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return synchronous_model ~= nil
  end, 10),
  "collector lost synchronously completed probes"
)
assert(#synchronous_model.components == 14)

print "opencode inventory collector tests passed"

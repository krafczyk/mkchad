local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = vim.fs.joinpath(root, "lua", "?.lua") .. ";" .. package.path
vim.opt.runtimepath:prepend(root)

for _, module in ipairs {
  "mkchad.opencode.inventory",
  "mkchad.opencode.inventory_collectors",
  "mkchad.opencode.inventory_evidence",
  "mkchad.opencode.inventory_host",
  "mkchad.opencode.contracts",
} do
  package.loaded[module] = nil
end
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
    mkchad_git = { code = 0, stdout = "0123456789abcdef0123456789abcdef01234567\n" },
    mkchad_dirty = { code = 1, error = true },
    opencode_nvim_git = { missing = true },
    opencode_nvim_dirty = { missing = true },
    sprint_nvim_git = { missing = true },
    sprint_nvim_dirty = { missing = true },
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
local drift_image_root = vim.fs.joinpath(fixture, "drift-image")
local drift_manifest = vim.fs.joinpath(drift_image_root, "component-manifest.json")
assert(vim.fn.mkdir(drift_image_root, "p", 448) ~= 0)
vim.fn.writefile({
  vim.json.encode {
    schema = 1,
    component_id = "nvim-image",
    relationships = {
      {
        id = "ships-opencode",
        type = "ships",
        target_component = "opencode",
        contract = { kind = "exact", version = "1.18.3", suffix_policy = "literal" },
      },
    },
  },
}, drift_manifest)
local drift_model = collectors.collect {
  image_root = drift_image_root,
  image_manifest = drift_manifest,
  image_uid = vim.uv.getuid(),
  probe_results = { opencode = { code = 0, stdout = "1.18.4\n" } },
  lifecycle = {
    persisted_state = "present",
    persisted_version = "1.18.4",
    running_state = "present",
    running_version = "1.18.4",
  },
}
for _, item in ipairs(drift_model.diagnostics) do
  assert(item.code ~= "opencode_layer_drift", "image-shipped baseline was included in OpenCode layer drift")
end
local layer_drift_model = collectors.collect {
  image_root = drift_image_root,
  image_manifest = drift_manifest,
  image_uid = vim.uv.getuid(),
  probe_results = { opencode = { code = 0, stdout = "1.18.4\n" } },
  lifecycle = {
    persisted_state = "present",
    persisted_version = "1.18.5",
    running_state = "present",
    running_version = "1.18.4",
  },
}
local layer_drift_diagnostics = 0
for _, item in ipairs(layer_drift_model.diagnostics) do
  if item.code == "opencode_layer_drift" then
    layer_drift_diagnostics = layer_drift_diagnostics + 1
  end
end
assert(layer_drift_diagnostics == 1, "selected, persisted, and running OpenCode drift was not reported once")

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
local legacy_cache_root = vim.fs.joinpath(
  cache_home,
  "opencode",
  "packages",
  "opencode-project-reload@legacy",
  "node_modules",
  "opencode-project-reload"
)
assert(vim.fn.mkdir(legacy_cache_root, "p", 448) ~= 0)
assert(vim.fn.mkdir(vim.fs.joinpath(legacy_cache_root, "dist"), "p", 448) ~= 0)
vim.fn.writefile({ runtime_bytes }, vim.fs.joinpath(legacy_cache_root, "dist", "tui.js"), "b")
local wrong_cache_owner = vim.deepcopy(package_owner)
wrong_cache_owner.component_id = "not-opencode-project-reload"
vim.fn.writefile({ vim.json.encode(wrong_cache_owner) }, vim.fs.joinpath(legacy_cache_root, "opencode-component.json"))
local cached_model = collectors.collect { cache_root = cache_home }
for _, item in ipairs(cached_model.observations) do
  if item.id == "opencode-project-reload:cached" then
    assert(item.state == "present" and item.identity == vim.fn.sha256(runtime_bytes), "versioned cache was not found")
  end
end
local unsafe_cache_root = vim.fs.joinpath(
  cache_home,
  "opencode",
  "packages",
  "opencode-project-reload@unsafe",
  "node_modules",
  "opencode-project-reload"
)
assert(vim.fn.mkdir(vim.fs.joinpath(unsafe_cache_root, "dist"), "p", 448) ~= 0)
vim.fn.writefile({ runtime_bytes }, vim.fs.joinpath(unsafe_cache_root, "dist", "tui.js"), "b")
vim.fn.writefile({ vim.json.encode(package_owner) }, vim.fs.joinpath(unsafe_cache_root, "opencode-component.json"))
assert(vim.uv.fs_chmod(vim.fs.joinpath(unsafe_cache_root, "dist"), 511))
local unsafe_cached_model = collectors.collect { cache_root = cache_home }
for _, item in ipairs(unsafe_cached_model.observations) do
  if item.id == "opencode-project-reload:cached" then
    assert(item.state == "unavailable", "indeterminate unsafe cache root did not fail closed")
  end
end
local ce_cache_root = vim.fs.joinpath(
  cache_home,
  "opencode",
  "packages",
  "compound-engineering@git+https:",
  "github.com",
  "example",
  "compound-engineering#fixture",
  "node_modules",
  "compound-engineering"
)
assert(vim.fn.mkdir(vim.fs.joinpath(ce_cache_root, "skills"), "p", 448) ~= 0)
vim.fn.writefile({ "current" }, vim.fs.joinpath(ce_cache_root, "skills", "routing.md"))
local ce_owner = {
  schema = 1,
  component_id = "compound-engineering",
  component_version = "3.20.0",
  relationships = {},
  identity_profile = {
    id = "compound-engineering-plugin-v1",
    algorithm = "sha256",
    included_roots = { "skills" },
    exclusions = {},
    max_regular_files = 4096,
    max_total_bytes = 16777216,
    max_per_file_bytes = 2097152,
    max_elapsed_ms = 5000,
    framing = "path-u32be-content-u64be-v1",
  },
}
vim.fn.writefile({ vim.json.encode(ce_owner) }, vim.fs.joinpath(ce_cache_root, "component.json"))
local invalid_ce_cache_root = vim.fs.joinpath(
  cache_home,
  "opencode",
  "packages",
  "compound-engineering@legacy",
  "node_modules",
  "compound-engineering"
)
assert(vim.fn.mkdir(invalid_ce_cache_root, "p", 448) ~= 0)
local invalid_ce_owner = vim.deepcopy(ce_owner)
invalid_ce_owner.identity_profile.included_roots = { "missing-runtime-content" }
vim.fn.writefile({ vim.json.encode(invalid_ce_owner) }, vim.fs.joinpath(invalid_ce_cache_root, "component.json"))
local ce_cached_model = collectors.collect { cache_root = cache_home }
for _, item in ipairs(ce_cached_model.observations) do
  if item.id == "compound-engineering:cached" then
    assert(
      item.state == "present" and item.version == "3.20.0",
      "content-invalid historical Compound Engineering cache root competed with the current root"
    )
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
local function successful_probe(argv)
  if vim.tbl_contains(argv, "rev-parse") then
    return { code = 0, stdout = "0123456789abcdef0123456789abcdef01234567\n" }
  end
  if vim.tbl_contains(argv, "diff") then
    return { code = 0, stdout = "" }
  end
  local name = vim.fs.basename(argv[1])
  return { code = 0, stdout = name == "git" and "git version 2.43.0\n" or "Python 3.12.3\n" }
end
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
      callback(successful_probe(argv))
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
    callback(successful_probe(argv))
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

local git_root = vim.fs.joinpath(fixture, "git-self-mutation")
assert(vim.fn.mkdir(git_root, "p", 448) ~= 0)
local git_executable = vim.fn.exepath "git"
assert(git_executable ~= "")
vim.fn.system { git_executable, "init", "-q", git_root }
assert(vim.v.shell_error == 0)
vim.fn.writefile({ "fixture" }, vim.fs.joinpath(git_root, "tracked"))
vim.fn.system { git_executable, "-C", git_root, "add", "tracked" }
assert(vim.v.shell_error == 0)
vim.fn.system {
  git_executable,
  "-C",
  git_root,
  "-c",
  "user.name=MkChad Test",
  "-c",
  "user.email=mkchad@example.invalid",
  "commit",
  "-qm",
  "fixture",
}
assert(vim.v.shell_error == 0)
local git_snapshot =
  assert(evidence.safe_snapshot(vim.fs.joinpath(git_root, ".git"), git_root, vim.uv.getuid(), "directory"))
local git_model
local git_sequence = {}
local finish_git = collectors.collect_async({
  config_root = git_root,
  executables = { opencode = false, sprint_loop = false, python = false, node = false, curl = false },
  probe = function(argv, options, callback)
    assert(not vim.tbl_contains(argv, "describe"), "collector used the mutating Git describe probe")
    if vim.tbl_contains(argv, git_root) then
      table.insert(git_sequence, vim.tbl_contains(argv, "rev-parse") and "identity" or "dirty")
    end
    vim.system(argv, {
      cwd = options.cwd,
      env = options.env,
      clear_env = options.replace_env,
      text = true,
      timeout = options.timeout_ms,
    }, function(completed)
      vim.schedule(function()
        callback({
          code = completed.code,
          signal = completed.signal,
          stdout = completed.stdout or "",
          stderr = completed.stderr or "",
        }, completed.code > 1 and completed.stderr or nil)
      end)
    end)
  end,
}, function(value)
  git_model = value
end)
finish_git { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return git_model ~= nil
  end, 10),
  "Git self-mutation collector did not finish"
)
for _, item in ipairs(git_model.observations) do
  if item.id == "mkchad:installed" then
    assert(
      item.state == "present"
        and item.identity == vim.trim(vim.fn.system { git_executable, "-C", git_root, "rev-parse", "HEAD" })
        and item.dirty == false,
      "Git collector did not preserve the exact clean checkout identity: " .. vim.inspect(item)
    )
  end
end
assert(vim.deep_equal(git_sequence, { "identity", "dirty", "identity", "dirty" }), "Git probes were not ordered safely")
assert(
  evidence.snapshot_unchanged(vim.fs.joinpath(git_root, ".git"), git_snapshot),
  "Git collector changed repository metadata"
)

local raced_model
local raced_calls = 0
local finish_raced = collectors.collect_async({
  config_root = git_root,
  executables = { opencode = false, sprint_loop = false, python = false, node = false, curl = false },
  probe = function(argv, _, callback)
    if vim.tbl_contains(argv, "rev-parse") then
      local identity = "0123456789abcdef0123456789abcdef01234567"
      if vim.tbl_contains(argv, git_root) then
        raced_calls = raced_calls + 1
        identity = raced_calls == 1 and identity or "89abcdef0123456789abcdef0123456789abcdef"
      end
      callback { code = 0, stdout = identity .. "\n" }
      return
    end
    callback(
      vim.tbl_contains(argv, "diff") and { code = 0, stdout = "" } or { code = 0, stdout = "git version 2.43.0\n" }
    )
  end,
}, function(value)
  raced_model = value
end)
finish_raced { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return raced_model ~= nil
  end, 10),
  "raced Git collector did not finish"
)
for _, item in ipairs(raced_model.observations) do
  if item.id == "mkchad:installed" then
    assert(item.state == "unavailable" and item.identity == nil, "raced Git identity was accepted")
  end
end

local dirty_raced_model
local dirty_calls = 0
local finish_dirty_raced = collectors.collect_async({
  config_root = git_root,
  executables = { opencode = false, sprint_loop = false, python = false, node = false, curl = false },
  probe = function(argv, _, callback)
    if vim.tbl_contains(argv, "rev-parse") then
      callback { code = 0, stdout = "0123456789abcdef0123456789abcdef01234567\n" }
      return
    end
    if vim.tbl_contains(argv, "diff") and vim.tbl_contains(argv, git_root) then
      dirty_calls = dirty_calls + 1
      callback { code = dirty_calls == 1 and 0 or 1, stdout = "" }
      return
    end
    callback(
      vim.tbl_contains(argv, "diff") and { code = 0, stdout = "" } or { code = 0, stdout = "git version 2.43.0\n" }
    )
  end,
}, function(value)
  dirty_raced_model = value
end)
finish_dirty_raced { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return dirty_raced_model ~= nil
  end, 10),
  "dirty-raced Git collector did not finish"
)
for _, item in ipairs(dirty_raced_model.observations) do
  if item.id == "mkchad:installed" then
    assert(item.state == "unavailable" and item.identity == nil, "raced Git dirty state was accepted")
  end
end

local timed_out_git = collectors.collect {
  probe_results = {
    mkchad_git = { code = 0, stdout = "0123456789abcdef0123456789abcdef01234567\n" },
    mkchad_dirty = { code = 1, timed_out = true, killed = true, signal = 15 },
  },
}
for _, item in ipairs(timed_out_git.observations) do
  if item.id == "mkchad:installed" then
    assert(item.state == "timed_out" and item.identity == nil, "timed-out Git dirty probe was accepted")
  end
end

local selected_npm_base = vim.fs.joinpath(fixture, "selected-npm")
local selected_npm = vim.fs.joinpath(selected_npm_base, "linux-x64-node24")
local selected_package = vim.fs.joinpath(selected_npm, "lib", "node_modules", "opencode-ai")
local selected_executable = vim.fs.joinpath(selected_package, "bin", "opencode")
assert(vim.fn.mkdir(vim.fs.dirname(selected_executable), "p", 448) ~= 0)
vim.fn.writefile({ "#!/bin/sh", "exit 99" }, selected_executable)
assert(vim.uv.fs_chmod(selected_executable, 493))
vim.fn.writefile({
  vim.json.encode {
    name = "opencode-ai",
    version = "1.18.9-mkchad.2",
    bin = { opencode = "./bin/opencode" },
  },
}, vim.fs.joinpath(selected_package, "package.json"))
local selected_invoked = false
local selected_model
local finish_selected = collectors.collect_async({
  config_root = root,
  npm_root = selected_npm_base,
  executables = {
    opencode = selected_executable,
    sprint_loop = false,
    git = false,
    python = false,
    node = false,
    curl = false,
  },
  probe = function(_, _, callback)
    selected_invoked = true
    callback { code = 99, stdout = "" }
  end,
}, function(value)
  selected_model = value
end)
finish_selected { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return selected_model ~= nil
  end, 10),
  "selected package collector did not finish"
)
assert(not selected_invoked, "selected OpenCode package was executed for version evidence")
for _, item in ipairs(selected_model.observations) do
  if item.id == "opencode:selected" then
    assert(item.state == "present" and item.version == "1.18.9-mkchad.2", "package identity was not selected")
  end
end

vim.fn.writefile({
  vim.json.encode {
    name = "not-opencode",
    version = "1.18.9-mkchad.2",
    bin = { opencode = "./bin/opencode" },
  },
}, vim.fs.joinpath(selected_package, "package.json"))
local invalid_selected_invoked = false
local invalid_selected_model
local finish_invalid_selected = collectors.collect_async({
  npm_root = selected_npm_base,
  executables = {
    opencode = selected_executable,
    sprint_loop = false,
    git = false,
    python = false,
    node = false,
    curl = false,
  },
  probe = function(_, _, callback)
    invalid_selected_invoked = true
    callback { code = 99, stdout = "" }
  end,
}, function(value)
  invalid_selected_model = value
end)
finish_invalid_selected { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return invalid_selected_model ~= nil
  end, 10),
  "invalid selected package collector did not finish"
)
assert(not invalid_selected_invoked, "invalid managed OpenCode package was executed")
for _, item in ipairs(invalid_selected_model.observations) do
  if item.id == "opencode:selected" then
    assert(item.state == "unavailable" and item.version == nil, "invalid package metadata was trusted")
  end
end

local image_base = vim.fs.joinpath(fixture, "image")
local image_runtime = vim.fs.joinpath(image_base, "node-v24")
local image_node = vim.fs.joinpath(image_runtime, "bin", "node")
assert(vim.fn.mkdir(vim.fs.dirname(image_node), "p", 448) ~= 0)
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, image_node)
assert(vim.uv.fs_chmod(image_node, 493))
local image_opencode_package = vim.fs.joinpath(image_runtime, "lib", "node_modules", "opencode-ai")
local image_opencode = vim.fs.joinpath(image_opencode_package, "bin", "opencode")
assert(vim.fn.mkdir(vim.fs.dirname(image_opencode), "p", 448) ~= 0)
vim.fn.writefile({ "#!/bin/sh", "exit 99" }, image_opencode)
assert(vim.uv.fs_chmod(image_opencode, 493))
vim.fn.writefile({
  vim.json.encode {
    name = "opencode-ai",
    version = "1.18.3-mkchad.7",
    bin = { opencode = "./bin/opencode" },
  },
}, vim.fs.joinpath(image_opencode_package, "package.json"))
local node_model
local image_opencode_invoked = false
local finish_node = collectors.collect_async({
  config_root = root,
  image_base = image_base,
  image_invoking_uid = vim.uv.getuid() + 1,
  executables = {
    opencode = image_opencode,
    sprint_loop = false,
    git = false,
    python = false,
    node = image_node,
    curl = false,
  },
  probe = function(argv, _, callback)
    if argv[1] ~= image_node then
      image_opencode_invoked = true
    end
    callback { code = 0, stdout = "v24.18.0\n" }
  end,
}, function(value)
  node_model = value
end)
finish_node { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return node_model ~= nil
  end, 10),
  "image runtime collector did not finish"
)
for _, item in ipairs(node_model.observations) do
  if item.id == "prereq-node:installed" then
    assert(item.state == "present" and item.version == "24.18.0", "image-owned Node runtime was not trusted")
  end
end
assert(not image_opencode_invoked, "image-managed OpenCode was executed for version evidence")
for _, item in ipairs(node_model.observations) do
  if item.id == "opencode:selected" then
    assert(item.state == "present" and item.version == "1.18.3-mkchad.7", "image OpenCode metadata was not used")
  end
end

local untrusted_node_invoked = false
local untrusted_node_model
local finish_untrusted_node = collectors.collect_async({
  image_base = image_base,
  executables = {
    opencode = false,
    sprint_loop = false,
    git = false,
    python = false,
    node = image_node,
    curl = false,
  },
  probe = function(_, _, callback)
    untrusted_node_invoked = true
    callback { code = 0, stdout = "v24.18.0\n" }
  end,
}, function(value)
  untrusted_node_model = value
end)
finish_untrusted_node { persisted_state = "absent", running_state = "unavailable" }
assert(
  vim.wait(5000, function()
    return untrusted_node_model ~= nil
  end, 10),
  "untrusted image runtime collector did not finish"
)
assert(not untrusted_node_invoked, "invoking-user-owned image runtime was executed")
for _, item in ipairs(untrusted_node_model.observations) do
  if item.id == "prereq-node:installed" then
    assert(item.state == "absent", "invoking-user-owned image runtime was trusted")
  end
end

print "opencode inventory collector tests passed"

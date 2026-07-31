local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = vim.fs.joinpath(root, "lua", "?.lua") .. ";" .. package.path

local inventory = require "mkchad.opencode.inventory"

local owner = assert(inventory.validate_owner({
  schema = 1,
  component_id = "opencode-nvim",
  relationships = {
    {
      id = "tested",
      type = "tested-with",
      target_component = "opencode",
      contract = { kind = "tested-baseline", version = "1.18.3", suffix_policy = "literal" },
    },
  },
  future_field = true,
}, "opencode-nvim"))
assert(owner.component_id == "opencode-nvim")
assert(owner.future_field == nil and owner.relationships[1].future_field == nil, "owner extensions leaked into output")
local future_relationship = assert(inventory.validate_owner({
  schema = 1,
  component_id = "opencode-nvim",
  relationships = {
    {
      id = "tested",
      type = "tested-with",
      target_component = "opencode",
      contract = { kind = "tested-baseline", version = "1.18.3", suffix_policy = "literal" },
      future_field = string.rep("x", 800),
    },
  },
}, "opencode-nvim"))
assert(future_relationship.relationships[1].future_field == nil, "unknown relationship field was published")

local duplicate = [[{"schema":1,"schema":1,"component_id":"opencode-nvim","relationships":[]}]]
assert(not inventory.decode_json(duplicate, 16 * 1024), "duplicate keys were accepted")
assert(not inventory.decode_json("{", 16 * 1024), "malformed JSON was accepted")
assert(not inventory.decode_json(string.rep("x", 16 * 1024 + 1), 16 * 1024), "oversized JSON was accepted")
assert(not inventory.validate_owner({ schema = 1, component_id = "opencode-nvim", relationships = {} }, "opencode"))
assert(not inventory.validate_owner({
  schema = 1,
  component_id = "opencode-project-reload",
  component_version = "not a version",
  relationships = {},
}, "opencode-project-reload"), "malformed component version was accepted")
assert(inventory.validate_owner({
  schema = 1,
  component_id = "opencode-project-reload",
  component_version = "0.1.0",
  relationships = {},
  identity_profile = {
    id = "opencode-project-reload-tui-v1",
    sha256 = string.rep("a", 64),
    included_roots = { "dist/tui.js" },
    exclusions = {},
    max_regular_files = 1,
    max_total_bytes = 1048576,
    max_per_file_bytes = 1048576,
    max_elapsed_ms = 1000,
    framing = "raw-file-bytes-v1",
  },
}, "opencode-project-reload"))
assert(inventory.validate_owner({
  schema = 1,
  component_id = "compound-engineering",
  component_version = "3.20.0",
  relationships = {},
  identity_profile = {
    id = "compound-engineering-plugin-v1",
    algorithm = "sha256",
    included_roots = { "component.json", "skills" },
    exclusions = { "node_modules" },
    max_regular_files = 4096,
    max_total_bytes = 16777216,
    max_per_file_bytes = 2097152,
    max_elapsed_ms = 5000,
    framing = "path-u32be-content-u64be-v1",
  },
}, "compound-engineering"))
assert(not inventory.validate_owner({
  schema = 1,
  component_id = "compound-engineering",
  relationships = {},
  identity_profile = {
    id = "compound-engineering-plugin-v1",
    algorithm = "sha1",
    included_roots = { "skills" },
    exclusions = {},
    max_regular_files = 1,
    max_total_bytes = 1,
    max_per_file_bytes = 1,
    max_elapsed_ms = 1,
    framing = "path-u32be-content-u64be-v1",
  },
}, "compound-engineering"), "unsupported digest algorithm was accepted")
assert(not inventory.validate_owner({
  schema = 1,
  component_id = "sprint-loop-controller",
  relationships = {
    {
      id = "reversed",
      type = "supports",
      target_component = "opencode",
      contract = {
        kind = "range",
        clauses = { { min_inclusive = "2.0.0", max_exclusive = "1.0.0" } },
        suffix_policy = "literal",
      },
    },
  },
}, "sprint-loop-controller"), "reversed compatibility range was accepted")
assert(not inventory.validate_owner({
  schema = 1,
  component_id = "opencode-nvim",
  relationships = {
    {
      id = "wrong-kind",
      type = "tested-with",
      target_component = "opencode",
      contract = { kind = "exact", version = "1.18.3", suffix_policy = "literal" },
    },
  },
}, "opencode-nvim"), "relationship accepted an incompatible contract kind")

local source_observation = { state = "present", version = "0.1.0" }
local target = { state = "present", version = "1.18.3-mkchad.7" }
local literal = { type = "supports", contract = { kind = "exact", version = "1.18.3", suffix_policy = "literal" } }
assert(inventory.evaluate(literal, source_observation, target) == "unsupported", "suffix was normalized")
local tested = { type = "tested-with", contract = literal.contract }
assert(inventory.evaluate(tested, source_observation, target) == "unknown", "tested baseline became unsupported")
local equivalent = {
  type = "supports",
  contract = {
    kind = "exact",
    version = "1.18.3",
    suffix_policy = "explicit-equivalence",
    equivalences = { { observed = "1.18.3-mkchad.7", equivalent_to = "1.18.3" } },
  },
}
assert(inventory.evaluate(equivalent, source_observation, target) == "satisfied")
local range_equivalent = {
  type = "supports",
  contract = {
    kind = "range",
    clauses = { { min_inclusive = "1.18.0", max_exclusive = "1.19.0" } },
    suffix_policy = "explicit-equivalence",
    equivalences = { { observed = "1.18.3-mkchad.7", equivalent_to = "1.18.3" } },
  },
}
assert(inventory.evaluate(range_equivalent, source_observation, target) == "satisfied")
assert(inventory.evaluate({
  type = "ships",
  contract = { kind = "exact", version = "1.18.3", suffix_policy = "literal" },
}, source_observation, { state = "present", version = "1.18.4" }) == "mismatch")
assert(inventory.evaluate({
  type = "supports",
  contract = {
    kind = "range",
    clauses = { { min_inclusive = "1.0.0", max_exclusive = "2.0.0" } },
    suffix_policy = "literal",
  },
}, source_observation, { state = "present", version = "01.2.3" }) == "unknown")

local loaded_from =
  { type = "loaded-from", contract = { kind = "identity", profile = "compound-engineering-plugin-v1" } }
assert(inventory.evaluate(loaded_from, {
  state = "present",
  version = "3.20.0",
  identity_kind = "compound-engineering-plugin-v1",
  identity = "a",
}, {
  state = "present",
  version = "3.20.0",
  identity_kind = "compound-engineering-plugin-v1",
  identity = "b",
}) == "stale", "equal-version comparable content drift was not stale")
assert(inventory.evaluate(loaded_from, {
  state = "present",
  identity_kind = "compound-engineering-plugin-v1",
  identity = "a",
}, {
  state = "present",
  identity_kind = "git-commit-v1",
  identity = "a",
}) == "unknown")

local components = {}
for _, id in ipairs(inventory.component_ids) do
  table.insert(components, { id = id, optional = false, disposition = "unavailable" })
end
local observations = {}
for _, id in ipairs(inventory.required_observation_ids) do
  local component, layer = id:match "^(.+):([^:]+)$"
  table.insert(observations, {
    id = id,
    component_id = component,
    layer = layer,
    state = "unavailable",
    evidence = string.rep("e", 64),
    diagnostic_ids = {},
  })
end
while #observations < 48 do
  table.insert(observations, {
    id = "maximal:" .. #observations,
    component_id = "mkchad",
    layer = "installed",
    state = "unavailable",
    evidence = string.rep("e", 64),
    diagnostic_ids = {},
  })
end
local diagnostics = {}
for index = 1, 24 do
  table.insert(diagnostics, {
    id = "diagnostic:maximal:" .. index,
    code = "unavailable_" .. string.rep("c", 48) .. index,
    message = string.rep("m", 256),
  })
end
local long_versions = {
  "1" .. string.rep("0", 94) .. "1",
  "1" .. string.rep("0", 94) .. "2",
  "1" .. string.rep("0", 94) .. "3",
}
local maximal_contract = {
  kind = "exact-set",
  versions = { long_versions[1] },
  suffix_policy = "explicit-equivalence",
  equivalences = {
    { observed = long_versions[2], equivalent_to = long_versions[1] },
    { observed = long_versions[3], equivalent_to = long_versions[1] },
  },
}
local relationships = {}
for index = 1, 28 do
  table.insert(relationships, {
    id = "maximal-owner-relationship:" .. index,
    type = "supports",
    owner = "mkchad",
    source_observation_id = inventory.required_observation_ids[1],
    target_observation_id = inventory.required_observation_ids[2],
    contract = maximal_contract,
    result = "unknown",
    diagnostic_ids = {},
  })
end
for index = 29, 32 do
  table.insert(relationships, {
    id = "maximal-loaded-relationship:" .. index,
    type = "loaded-from",
    owner = "mkchad",
    source_observation_id = inventory.required_observation_ids[1],
    target_observation_id = inventory.required_observation_ids[2],
    contract = { kind = "identity", profile = "compound-engineering-plugin-v1" },
    result = "unknown",
    diagnostic_ids = {},
  })
end
local maximal = inventory.model(components, observations, relationships, diagnostics)
assert(#vim.json.encode(maximal) < 48 * 1024, "maximal inventory exceeded its model bound")
assert(#vim.json.encode {
  schema = 1,
  ok = true,
  command = "status",
  status = "blocked",
  state = vim.NIL,
  diagnostic = { code = string.rep("c", 64), message = string.rep("m", 1024) },
  inventory = maximal,
} < 60 * 1024, "maximal status envelope exceeded its command bound")

print "opencode inventory tests passed"

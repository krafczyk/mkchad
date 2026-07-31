-- Pure inventory model, owner-contract validator, relationship evaluator, and
-- renderers. Collection intentionally lives in inventory_collectors.lua.
local M = {}

M.component_ids = {
  "mkchad",
  "container-runtime",
  "nvim-image",
  "opencode",
  "opencode-nvim",
  "opencode-project-reload",
  "compound-engineering",
  "sprint-loop-controller",
  "sprint-loop-nvim",
  "prereq-neovim",
  "prereq-git",
  "prereq-python",
  "prereq-node",
  "prereq-curl",
}
M.layers = { "declared", "shipped", "installed", "cached", "selected", "loaded", "persisted", "running" }
M.states = {
  present = true,
  absent = true,
  not_applicable = true,
  unavailable = true,
  not_discoverable = true,
  unqueried = true,
  timed_out = true,
  unprovable = true,
}
M.required_observation_ids = {
  "container-runtime:installed",
  "nvim-image:shipped",
  "nvim-image:selected",
  "nvim-image:persisted",
  "mkchad:declared",
  "mkchad:installed",
  "opencode:shipped",
  "opencode:selected",
  "opencode:persisted",
  "opencode:running",
  "opencode-nvim:declared",
  "opencode-nvim:installed",
  "opencode-nvim:loaded",
  "opencode-project-reload:installed",
  "opencode-project-reload:cached",
  "opencode-project-reload:loaded",
  "compound-engineering:installed",
  "compound-engineering:cached",
  "compound-engineering:loaded",
  "sprint-loop-controller:installed",
  "sprint-loop-nvim:installed",
  "sprint-loop-nvim:loaded",
  "prereq-neovim:shipped",
  "prereq-neovim:installed",
  "prereq-git:installed",
  "prereq-python:installed",
  "prereq-node:shipped",
  "prereq-node:installed",
  "prereq-curl:installed",
}

local ids, layers = {}, {}
for _, value in ipairs(M.component_ids) do
  ids[value] = true
end
for _, value in ipairs(M.layers) do
  layers[value] = true
end

local relationship_types = {
  ships = true,
  requires = true,
  supports = true,
  ["tested-with"] = true,
  ["loaded-from"] = true,
}
local owner_relationship_types = { ships = true, requires = true, supports = true, ["tested-with"] = true }
local function control_free(value, maximum)
  return type(value) == "string"
    and #value > 0
    and #value <= maximum
    and not value:find "[%z\1-\31\127]"
    and pcall(vim.str_utfindex, value)
end

local function ascii_id(value, maximum)
  return control_free(value, maximum) and value:match "^[A-Za-z0-9._:-]+$" ~= nil
end

local function positive_integer(value, maximum)
  return type(value) == "number" and value % 1 == 0 and value > 0 and value <= maximum
end

local function complete_version(value)
  return control_free(value, 128) and value:match "^[0-9][0-9A-Za-z.+_-]*$" ~= nil
end

local function array(value, maximum)
  return type(value) == "table" and (next(value) == nil or vim.islist(value)) and #value <= maximum
end

-- vim.json.decode intentionally accepts duplicate object keys. Detect them
-- before decoding, without interpreting values or allowing an owner artifact
-- to silently override a declaration.
local function unique_json_object_keys(raw)
  local position, length = 1, #raw
  local function whitespace()
    while position <= length and raw:sub(position, position):match "%s" do
      position = position + 1
    end
  end
  local parse_value
  local function string_value()
    if raw:sub(position, position) ~= '"' then
      return nil
    end
    local start = position
    position = position + 1
    while position <= length do
      local char = raw:sub(position, position)
      if char == "\\" then
        position = position + 2
      elseif char == '"' then
        local token = raw:sub(start, position)
        position = position + 1
        local ok, value = pcall(vim.json.decode, token)
        return ok and value or nil
      elseif char:byte() < 32 then
        return nil
      else
        position = position + 1
      end
    end
  end
  local function object()
    if raw:sub(position, position) ~= "{" then
      return false
    end
    position = position + 1
    whitespace()
    local seen = {}
    if raw:sub(position, position) == "}" then
      position = position + 1
      return true
    end
    while true do
      local key = string_value()
      if not key or seen[key] then
        return false
      end
      seen[key] = true
      whitespace()
      if raw:sub(position, position) ~= ":" then
        return false
      end
      position = position + 1
      whitespace()
      if not parse_value() then
        return false
      end
      whitespace()
      local delimiter = raw:sub(position, position)
      if delimiter == "}" then
        position = position + 1
        return true
      end
      if delimiter ~= "," then
        return false
      end
      position = position + 1
      whitespace()
    end
  end
  local function list()
    if raw:sub(position, position) ~= "[" then
      return false
    end
    position = position + 1
    whitespace()
    if raw:sub(position, position) == "]" then
      position = position + 1
      return true
    end
    while true do
      if not parse_value() then
        return false
      end
      whitespace()
      local delimiter = raw:sub(position, position)
      if delimiter == "]" then
        position = position + 1
        return true
      end
      if delimiter ~= "," then
        return false
      end
      position = position + 1
      whitespace()
    end
  end
  parse_value = function()
    whitespace()
    local char = raw:sub(position, position)
    if char == "{" then
      return object()
    elseif char == "[" then
      return list()
    elseif char == '"' then
      return string_value() ~= nil
    end
    local token = raw:match("^[^,%]%}%s]+", position)
    if not token then
      return false
    end
    position = position + #token
    return token == "true" or token == "false" or token == "null" or tonumber(token) ~= nil
  end
  whitespace()
  local valid = parse_value()
  whitespace()
  return valid and position > length
end

function M.decode_json(raw, maximum)
  if type(raw) ~= "string" or #raw == 0 or #raw > maximum or not pcall(vim.str_utfindex, raw) then
    return nil, "invalid-json-size-or-utf8"
  end
  if not unique_json_object_keys(raw) then
    return nil, "invalid-or-duplicate-json"
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok then
    return nil, "invalid-json"
  end
  return decoded
end

local function validate_suffix(contract)
  if contract.suffix_policy ~= "literal" and contract.suffix_policy ~= "explicit-equivalence" then
    return false
  end
  if contract.suffix_policy == "literal" then
    return contract.equivalences == nil
  end
  if not array(contract.equivalences, 4) then
    return false
  end
  local seen = {}
  for _, item in ipairs(contract.equivalences) do
    if type(item) ~= "table" or not complete_version(item.observed) or not complete_version(item.equivalent_to) then
      return false
    end
    if seen[item.observed] then
      return false
    end
    seen[item.observed] = true
  end
  return true
end

local function normalize_contract(contract)
  local normalized = { kind = contract.kind }
  if contract.kind == "identity" then
    normalized.profile = contract.profile
    return normalized
  end
  normalized.suffix_policy = contract.suffix_policy
  if contract.version then
    normalized.version = contract.version
  end
  if contract.versions then
    normalized.versions = vim.deepcopy(contract.versions)
  end
  if contract.clauses then
    normalized.clauses = {}
    for _, clause in ipairs(contract.clauses) do
      table.insert(normalized.clauses, {
        min_inclusive = clause.min_inclusive,
        max_exclusive = clause.max_exclusive,
      })
    end
  end
  if contract.equivalences then
    normalized.equivalences = {}
    for _, item in ipairs(contract.equivalences) do
      table.insert(normalized.equivalences, { observed = item.observed, equivalent_to = item.equivalent_to })
    end
  end
  return normalized
end

local function normalize_identity_profile(profile)
  if not profile then
    return nil
  end
  return {
    id = profile.id,
    algorithm = profile.algorithm,
    sha256 = profile.sha256,
    included_roots = vim.deepcopy(profile.included_roots),
    exclusions = vim.deepcopy(profile.exclusions),
    max_regular_files = profile.max_regular_files,
    max_total_bytes = profile.max_total_bytes,
    max_per_file_bytes = profile.max_per_file_bytes,
    max_elapsed_ms = profile.max_elapsed_ms,
    framing = profile.framing,
  }
end

local semver
local compare

local function validate_contract(contract)
  if type(contract) ~= "table" or type(contract.kind) ~= "string" then
    return false
  end
  if contract.kind == "identity" then
    return control_free(contract.profile, 64)
  end
  if not validate_suffix(contract) then
    return false
  end
  if contract.kind == "exact" or contract.kind == "tested-baseline" then
    return complete_version(contract.version)
  elseif contract.kind == "exact-set" then
    if not array(contract.versions, 4) or #contract.versions == 0 then
      return false
    end
    local seen = {}
    for _, version in ipairs(contract.versions) do
      if not complete_version(version) or seen[version] then
        return false
      end
      seen[version] = true
    end
    return true
  elseif contract.kind == "range" then
    if not array(contract.clauses, 8) or #contract.clauses == 0 then
      return false
    end
    local seen = {}
    for _, clause in ipairs(contract.clauses) do
      if type(clause) ~= "table" or not complete_version(clause.min_inclusive) then
        return false
      end
      if clause.max_exclusive ~= nil and not complete_version(clause.max_exclusive) then
        return false
      end
      local minimum = semver(clause.min_inclusive)
      local maximum = clause.max_exclusive and semver(clause.max_exclusive)
      local key = clause.min_inclusive .. "\0" .. (clause.max_exclusive or "")
      if not minimum or clause.max_exclusive and (not maximum or compare(minimum, maximum) >= 0) or seen[key] then
        return false
      end
      seen[key] = true
    end
    return true
  end
  return false
end

local function safe_relative_path(value)
  if not control_free(value, 256) or value:find "[^ -~]" or value:sub(1, 1) == "/" then
    return false
  end
  for part in value:gmatch "[^/]+" do
    if part == "." or part == ".." then
      return false
    end
  end
  return value ~= "" and not value:find "//"
end

local function validate_identity_profile(profile)
  if type(profile) ~= "table" or not ascii_id(profile.id, 64) then
    return false
  end
  if profile.algorithm ~= nil and profile.algorithm ~= "sha256" then
    return false
  end
  if
    profile.sha256 ~= nil
    and (type(profile.sha256) ~= "string" or #profile.sha256 ~= 64 or not profile.sha256:match "^[0-9a-f]+$")
  then
    return false
  end
  if profile.algorithm == nil and profile.sha256 == nil then
    return false
  end
  if
    not array(profile.included_roots, 32)
    or #profile.included_roots == 0
    or not array(profile.exclusions, 32)
    or not positive_integer(profile.max_regular_files, 4096)
    or not positive_integer(profile.max_total_bytes, 16 * 1024 * 1024)
    or not positive_integer(profile.max_per_file_bytes, 2 * 1024 * 1024)
    or not positive_integer(profile.max_elapsed_ms, 5000)
    or not ascii_id(profile.framing, 64)
  then
    return false
  end
  if profile.max_per_file_bytes > profile.max_total_bytes then
    return false
  end
  local seen = {}
  for _, paths in ipairs { profile.included_roots, profile.exclusions } do
    for _, path in ipairs(paths) do
      if not safe_relative_path(path) or seen[path] then
        return false
      end
      seen[path] = true
    end
  end
  if profile.framing == "raw-file-bytes-v1" then
    return profile.sha256 ~= nil and profile.algorithm == nil and #profile.included_roots == 1
  end
  return profile.framing == "path-u32be-content-u64be-v1" and profile.algorithm == "sha256" and profile.sha256 == nil
end

function M.validate_owner(value, expected_component)
  if type(value) ~= "table" or value.schema ~= 1 or value.component_id ~= expected_component then
    return nil, "owner-schema-or-component"
  end
  if value.component_version ~= nil and not complete_version(value.component_version) then
    return nil, "owner-version"
  end
  if value.build_id ~= nil and not control_free(value.build_id, 128) then
    return nil, "owner-build-id"
  end
  if value.identity_profile ~= nil and not validate_identity_profile(value.identity_profile) then
    return nil, "owner-identity-profile"
  end
  if not array(value.relationships, expected_component == "nvim-image" and 8 or 4) then
    return nil, "owner-relationships"
  end
  local seen = {}
  local normalized = {
    schema = 1,
    component_id = value.component_id,
    component_version = value.component_version,
    build_id = value.build_id,
    identity_profile = normalize_identity_profile(value.identity_profile),
    relationships = {},
  }
  for _, relationship in ipairs(value.relationships) do
    if
      type(relationship) ~= "table"
      or not ascii_id(relationship.id, 64)
      or seen[relationship.id]
      or not owner_relationship_types[relationship.type]
      or not ids[relationship.target_component]
      or not validate_contract(relationship.contract)
      or relationship.type == "ships" and relationship.contract.kind ~= "exact" and relationship.contract.kind ~= "identity"
      or relationship.type == "requires" and relationship.contract.kind ~= "exact" and relationship.contract.kind ~= "range"
      or relationship.type == "supports" and relationship.contract.kind ~= "exact-set" and relationship.contract.kind ~= "range"
      or relationship.type == "tested-with" and relationship.contract.kind ~= "tested-baseline"
    then
      return nil, "owner-relationship"
    end
    local normalized_relationship = {
      id = relationship.id,
      type = relationship.type,
      target_component = relationship.target_component,
      contract = normalize_contract(relationship.contract),
    }
    local encoded = vim.json.encode(normalized_relationship)
    if #encoded > 768 then
      return nil, "owner-relationship-size"
    end
    seen[relationship.id] = true
    table.insert(normalized.relationships, normalized_relationship)
  end
  return normalized
end

local function equivalent(contract, observed, expected)
  if observed == expected then
    return true
  end
  if contract.suffix_policy ~= "explicit-equivalence" then
    return false
  end
  for _, item in ipairs(contract.equivalences or {}) do
    if item.observed == observed and item.equivalent_to == expected then
      return true
    end
  end
  return false
end

semver = function(value)
  local major, minor, patch, suffix = value:match "^(%d+)%.(%d+)%.(%d+)(.*)$"
  if not major then
    return nil, "invalid"
  end
  if
    (#major > 1 and major:sub(1, 1) == "0")
    or (#minor > 1 and minor:sub(1, 1) == "0")
    or (#patch > 1 and patch:sub(1, 1) == "0")
  then
    return nil, "invalid"
  end
  if suffix ~= "" then
    return nil, "suffix"
  end
  return { major, minor, patch }
end

compare = function(left, right)
  for index = 1, 3 do
    if left[index] ~= right[index] then
      if #left[index] ~= #right[index] then
        return #left[index] < #right[index] and -1 or 1
      end
      return left[index] < right[index] and -1 or 1
    end
  end
  return 0
end

function M.evaluate(relationship, source, target)
  if source and source.state == "not_applicable" or target and target.state == "not_applicable" then
    return "not_applicable"
  end
  if not source or not target or source.state ~= "present" or target.state ~= "present" then
    return "unknown"
  end
  local contract = relationship.contract
  if relationship.type == "loaded-from" or contract.kind == "identity" then
    if not source.identity or not target.identity then
      return "unknown"
    end
    if source.identity_kind ~= contract.profile or target.identity_kind ~= contract.profile then
      return "unknown"
    end
    if source.dirty or target.dirty then
      return relationship.type == "ships" and "mismatch" or "stale"
    end
    if source.identity == target.identity then
      return "satisfied"
    end
    return relationship.type == "ships" and "mismatch" or "stale"
  end
  if not target.version then
    return "unknown"
  end
  if contract.kind == "exact" or contract.kind == "tested-baseline" then
    local matches = equivalent(contract, target.version, contract.version)
    if matches then
      return "satisfied"
    end
    if relationship.type == "tested-with" then
      return "unknown"
    end
    return relationship.type == "ships" and "mismatch" or "unsupported"
  elseif contract.kind == "exact-set" then
    for _, version in ipairs(contract.versions) do
      if equivalent(contract, target.version, version) then
        return "satisfied"
      end
    end
    if relationship.type == "tested-with" then
      return "unknown"
    end
    return relationship.type == "ships" and "mismatch" or "unsupported"
  elseif contract.kind == "range" then
    local candidate_version = target.version
    if contract.suffix_policy == "explicit-equivalence" then
      for _, item in ipairs(contract.equivalences or {}) do
        if item.observed == candidate_version then
          candidate_version = item.equivalent_to
          break
        end
      end
    end
    local candidate, candidate_error = semver(candidate_version)
    if not candidate then
      if candidate_error == "suffix" and relationship.type ~= "tested-with" then
        return relationship.type == "ships" and "mismatch" or "unsupported"
      end
      return "unknown"
    end
    for _, clause in ipairs(contract.clauses) do
      local minimum, maximum = semver(clause.min_inclusive), clause.max_exclusive and semver(clause.max_exclusive)
      if not minimum or (clause.max_exclusive and not maximum) then
        return "unknown"
      end
      if compare(candidate, minimum) >= 0 and (not maximum or compare(candidate, maximum) < 0) then
        return "satisfied"
      end
    end
    if relationship.type == "tested-with" then
      return "unknown"
    end
    return relationship.type == "ships" and "mismatch" or "unsupported"
  end
  return "unknown"
end

function M.model(components, observations, relationships, diagnostics)
  if #components > 14 or #observations > 48 or #relationships > 32 or #diagnostics > 24 then
    error "inventory bounds exceeded"
  end
  local component_seen, observation_seen, relationship_seen, diagnostic_seen = {}, {}, {}, {}
  for index, component in ipairs(components) do
    if
      type(component) ~= "table"
      or component.id ~= M.component_ids[index]
      or component_seen[component.id]
      or type(component.optional) ~= "boolean"
      or not M.states[component.disposition]
    then
      error "invalid inventory component"
    end
    component_seen[component.id] = true
  end
  if #components ~= #M.component_ids then
    error "inventory component coverage incomplete"
  end
  local partial = false
  for _, observation in ipairs(observations) do
    if
      type(observation) ~= "table"
      or not ascii_id(observation.id, 128)
      or observation_seen[observation.id]
      or not ids[observation.component_id]
      or not layers[observation.layer]
      or not M.states[observation.state]
      or not ascii_id(observation.evidence, 64)
      or observation.version ~= nil and not control_free(observation.version, 128)
      or observation.identity_kind ~= nil and not ascii_id(observation.identity_kind, 64)
      or observation.identity ~= nil and not control_free(observation.identity, 128)
      or observation.label ~= nil and not control_free(observation.label, 64)
      or observation.runtime_family ~= nil and observation.runtime_family ~= "apptainer" and observation.runtime_family ~= "singularity"
      or not array(observation.diagnostic_ids or {}, 8)
    then
      error "invalid inventory observation"
    end
    observation_seen[observation.id] = true
    if
      observation.state == "unavailable"
      or observation.state == "not_discoverable"
      or observation.state == "unqueried"
      or observation.state == "timed_out"
    then
      partial = true
    end
  end
  for _, observation_id in ipairs(M.required_observation_ids) do
    if not observation_seen[observation_id] then
      error "inventory observation coverage incomplete"
    end
  end
  for _, diagnostic in ipairs(diagnostics) do
    if
      type(diagnostic) ~= "table"
      or not ascii_id(diagnostic.id, 64)
      or diagnostic_seen[diagnostic.id]
      or not ascii_id(diagnostic.code, 64)
      or not control_free(diagnostic.message, 256)
    then
      error "invalid inventory diagnostic"
    end
    diagnostic_seen[diagnostic.id] = true
    if
      diagnostic.code:find("unavailable", 1, true)
      or diagnostic.code:find("invalid", 1, true)
      or diagnostic.code:find("unsafe", 1, true)
      or diagnostic.code:find("raced", 1, true)
      or diagnostic.code:find("timed_out", 1, true)
      or diagnostic.code == "collector_internal_error"
    then
      partial = true
    end
  end
  local outcomes = { satisfied = 0, unsupported = 0, stale = 0, mismatch = 0, unknown = 0, not_applicable = 0 }
  for _, relationship in ipairs(relationships) do
    if
      type(relationship) ~= "table"
      or not ascii_id(relationship.id, 128)
      or relationship_seen[relationship.id]
      or not relationship_types[relationship.type]
      or not ids[relationship.owner]
      or not observation_seen[relationship.source_observation_id]
      or relationship.target_observation_id ~= nil and not observation_seen[relationship.target_observation_id]
      or not outcomes[relationship.result]
      or not validate_contract(relationship.contract)
      or not array(relationship.diagnostic_ids or {}, 8)
    then
      error "invalid inventory relationship"
    end
    relationship_seen[relationship.id] = true
    outcomes[relationship.result] = outcomes[relationship.result] + 1
  end
  local model = {
    schema = 1,
    complete = not partial,
    components = components,
    observations = observations,
    relationships = relationships,
    diagnostics = diagnostics,
    summary = {
      components = #components,
      observations = #observations,
      relationships = #relationships,
      diagnostics = #diagnostics,
      evaluations = outcomes,
    },
  }
  if #vim.json.encode(model) >= 48 * 1024 then
    error "inventory output bound exceeded"
  end
  return model
end

function M.human(model)
  local grouped, expanded, not_attested, observation_by_id = {}, {}, {}, {}
  for _, component in ipairs(model.components) do
    local disposition = component.disposition or "present"
    if disposition == "absent" and component.optional then
      disposition = "optional-absent"
    end
    grouped[disposition] = grouped[disposition] or {}
    table.insert(grouped[disposition], component.id)
  end
  for _, observation in ipairs(model.observations) do
    observation_by_id[observation.id] = observation
    if observation.layer == "loaded" and observation.state == "unprovable" then
      table.insert(not_attested, observation.component_id)
    end
    if
      observation.state == "unavailable"
      or observation.state == "not_discoverable"
      or observation.state == "unqueried"
      or observation.state == "timed_out"
    then
      local diagnostic = observation.diagnostic_ids and observation.diagnostic_ids[1]
      table.insert(
        expanded,
        "Inventory " .. observation.id .. ": " .. observation.state .. (diagnostic and " [" .. diagnostic .. "]" or "")
      )
    end
  end
  local active_contracts, active_unknown, active_incompatible = 0, false, false
  for _, relation in ipairs(model.relationships) do
    local target = relation.target_observation_id and observation_by_id[relation.target_observation_id]
    local baseline = observation_by_id["opencode:shipped"]
    if
      relation.type == "ships"
      and relation.owner == "nvim-image"
      and relation.target_observation_id == "opencode:selected"
      and relation.contract.kind == "exact"
      and relation.result == "mismatch"
      and baseline
      and baseline.state == "present"
      and baseline.version
      and equivalent(relation.contract, baseline.version, relation.contract.version)
      and target
      and target.state == "present"
      and target.version
    then
      table.insert(
        expanded,
        "Inventory image-shipped OpenCode baseline "
          .. baseline.version
          .. " is overridden by selected package "
          .. target.version
      )
    elseif relation.result ~= "satisfied" and relation.result ~= "not_applicable" then
      table.insert(expanded, "Inventory " .. relation.id .. ": " .. relation.result)
    end
    if
      (relation.type == "requires" or relation.type == "supports" or relation.type == "tested-with")
      and target
      and target.state == "present"
      and (target.layer == "selected" or target.layer == "persisted" or target.layer == "running")
    then
      active_contracts = active_contracts + 1
      if relation.result == "unsupported" or relation.result == "stale" or relation.result == "mismatch" then
        active_incompatible = true
      elseif relation.result ~= "satisfied" and relation.result ~= "not_applicable" then
        active_unknown = true
      end
    end
  end
  for _, diagnostic in ipairs(model.diagnostics) do
    table.insert(expanded, "Inventory " .. diagnostic.id .. ": " .. diagnostic.code .. " - " .. diagnostic.message)
  end
  local lines = { "Inventory: " .. (model.complete and "complete" or "partial") }
  for _, state in ipairs {
    "present",
    "optional-absent",
    "absent",
    "not_applicable",
    "unprovable",
    "unavailable",
    "not_discoverable",
  } do
    if grouped[state] then
      table.insert(lines, "Inventory " .. state:gsub("-", " ") .. ": " .. table.concat(grouped[state], ", "))
    end
  end
  if #not_attested > 0 then
    table.insert(lines, "Inventory not attested: " .. table.concat(not_attested, ", "))
  end
  local opencode_layers = {}
  for _, layer in ipairs { "selected", "persisted", "running" } do
    local observation = observation_by_id["opencode:" .. layer]
    if observation and observation.state == "present" then
      local identity = observation.identity_kind
          and observation.identity
          and observation.identity_kind .. ":" .. observation.identity
        or "unknown"
      table.insert(
        opencode_layers,
        layer .. " version " .. (observation.version or "unknown") .. " identity " .. identity
      )
    end
  end
  if #opencode_layers > 0 then
    table.insert(lines, "Inventory OpenCode layers: " .. table.concat(opencode_layers, ", "))
  end
  local repository_backed, running = {}, {}
  for _, observation in ipairs(model.observations) do
    local detail = observation.version and "version " .. observation.version or nil
    if observation.identity_kind and observation.identity then
      detail = (detail and detail .. " " or "")
        .. "identity "
        .. observation.identity_kind
        .. ":"
        .. observation.identity
    end
    if
      observation.layer == "installed"
      and observation.state == "present"
      and observation.identity_kind == "git-commit-v1"
    then
      local worktree = type(observation.dirty) == "boolean"
          and (observation.dirty and " worktree dirty" or " worktree clean")
        or ""
      table.insert(
        repository_backed,
        observation.component_id .. " installed " .. (detail or "identity unknown") .. worktree
      )
    elseif
      observation.component_id ~= "opencode"
      and observation.layer == "running"
      and observation.state == "present"
    then
      table.insert(running, observation.component_id .. " " .. (detail or "identity unknown"))
    end
  end
  if #repository_backed > 0 then
    table.insert(lines, "Inventory repository-backed: " .. table.concat(repository_backed, ", "))
  end
  if #running > 0 then
    table.insert(lines, "Inventory running: " .. table.concat(running, ", "))
  end
  local compatibility = active_incompatible and "incompatible"
    or active_contracts > 0 and not active_unknown and "compatible"
    or "unknown"
  table.insert(lines, "Inventory active compatibility: " .. compatibility)
  for _, line in ipairs(expanded) do
    table.insert(lines, line)
  end
  return table.concat(lines, "\n")
end

return M

local inventory = require "mkchad.opencode.inventory"
local contracts = require "mkchad.opencode.contracts"
local evidence = require "mkchad.opencode.inventory_evidence"
local host_transport = require "mkchad.opencode.inventory_host"
local M = {}

local uv = vim.uv
local bit = bit
local owner_limit = 16 * 1024
local optional = {
  ["opencode-project-reload"] = true,
  ["compound-engineering"] = true,
  ["sprint-loop-controller"] = true,
  ["sprint-loop-nvim"] = true,
}

local function bounded(value, maximum)
  return type(value) == "string"
    and #value > 0
    and #value <= maximum
    and not value:find "[%z\1-\31\127]"
    and pcall(vim.str_utfindex, value)
end

local function diagnostic(list, code, message)
  if #list >= 24 then
    return nil
  end
  local id = "diagnostic:" .. code
  local suffix = 2
  local existing = {}
  for _, item in ipairs(list) do
    existing[item.id] = true
  end
  while existing[id] do
    id = "diagnostic:" .. code .. ":" .. suffix
    suffix = suffix + 1
  end
  table.insert(list, { id = id, code = code:sub(1, 64), message = message:sub(1, 256) })
  return id
end

local function observation(component, layer, state, evidence, extra, diagnostic_ids)
  local value = {
    id = component .. ":" .. layer,
    component_id = component,
    layer = layer,
    state = state,
    evidence = evidence,
    diagnostic_ids = diagnostic_ids or {},
  }
  for key, item in pairs(extra or {}) do
    if item ~= nil then
      value[key] = item
    end
  end
  return value
end

M.decode_host_evidence = host_transport.decode

local function read_owner(path, root, component, expected_uid, diagnostics, deadline_ns)
  if deadline_ns and uv.hrtime() >= deadline_ns then
    return nil, "timed_out", diagnostic(diagnostics, "owner_metadata_timed_out", "Owner metadata deadline expired")
  end
  local raw, read_err = evidence.read_regular(path, root, owner_limit, expected_uid)
  if not raw then
    local diagnostic_id
    if read_err ~= "missing" then
      diagnostic_id = diagnostic(diagnostics, "owner_metadata_" .. read_err, "Owner metadata could not be safely read")
    end
    return nil, read_err, diagnostic_id
  end
  if deadline_ns and uv.hrtime() >= deadline_ns then
    return nil, "timed_out", diagnostic(diagnostics, "owner_metadata_timed_out", "Owner metadata deadline expired")
  end
  local decoded, parse_err = inventory.decode_json(raw, owner_limit)
  local valid, valid_err = decoded and inventory.validate_owner(decoded, component)
  if not valid then
    return nil, parse_err or valid_err, diagnostic(diagnostics, "owner_metadata_invalid", "Owner metadata is invalid")
  end
  return valid
end

local function executable_identity(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return table.concat({ stat.dev, stat.ino, stat.size, stat.mtime.sec, stat.ctime.sec }, ":")
end

local function probe_state(result)
  if result == nil then
    return "not_discoverable"
  end
  if result.missing then
    return "absent"
  end
  if result.timed_out then
    return "timed_out"
  end
  if result.error or result.code ~= 0 then
    return "unavailable"
  end
  return "present"
end

local function parse_version(result, pattern, first_line)
  if probe_state(result) ~= "present" then
    return nil
  end
  if type(result.stdout) ~= "string" or #result.stdout > 4096 or not pcall(vim.str_utfindex, result.stdout) then
    return nil
  end
  local line = first_line and result.stdout:match "^([^\r\n]+)" or result.stdout:match "^([^\r\n]+)[\r\n]*$"
  local version = line and line:match(pattern)
  return bounded(version, 128) and version or nil
end

local function add_probe_observation(observations, diagnostics, component, result, evidence, pattern, extra, first_line)
  local state = probe_state(result)
  local version = parse_version(result, pattern, first_line)
  local diagnostic_ids = {}
  if state == "present" and not version then
    state = "unavailable"
  end
  if state == "timed_out" or state == "unavailable" then
    local id = diagnostic(
      diagnostics,
      state == "timed_out" and "probe_timed_out" or "probe_unavailable",
      "A bounded component probe did not return valid identity evidence"
    )
    if id then
      table.insert(diagnostic_ids, id)
    end
  end
  extra = extra or {}
  extra.version = version
  table.insert(observations, observation(component, "installed", state, evidence, extra, diagnostic_ids))
end

local function default_paths(options)
  if options.fallback then
    return {
      image_root = "/nonexistent",
      image_manifest = "/nonexistent/component-manifest.json",
      lazy_root = "/nonexistent/lazy",
      opencode_nvim = "/nonexistent/opencode.nvim",
      sprint_nvim = "/nonexistent/sprint-loop.nvim",
      project_installed = nil,
      ce_installed = nil,
      cache_packages = "/nonexistent/packages",
    }
  end
  local data = options.data_root or vim.fn.stdpath "data"
  local cache = options.cache_root or vim.fs.dirname(vim.fn.stdpath "cache")
  local npm = options.npm_root or vim.env.MSK_NPM_GLOBAL_ROOT
  return {
    image_root = options.image_root or "/usr/share/mkchad",
    image_manifest = options.image_manifest or "/usr/share/mkchad/component-manifest.json",
    lazy_root = vim.fs.joinpath(data, "lazy"),
    opencode_nvim = options.opencode_nvim_root or vim.fs.joinpath(data, "lazy", "opencode.nvim"),
    sprint_nvim = options.sprint_nvim_root or vim.fs.joinpath(data, "lazy", "opencode_sprint_loop.lua"),
    project_installed = npm and vim.fs.joinpath(npm, "lib", "node_modules", "opencode-project-reload") or nil,
    ce_installed = npm and vim.fs.joinpath(npm, "lib", "node_modules", "compound-engineering") or nil,
    cache_packages = vim.fs.joinpath(cache, "opencode", "packages"),
  }
end

local installed_package

local function cached_package(
  observations,
  declarations,
  diagnostics,
  component,
  packages_root,
  explicit_root,
  metadata_name,
  expected_uid,
  deadline_ns
)
  if explicit_root then
    installed_package(
      observations,
      declarations,
      diagnostics,
      component,
      "cached",
      explicit_root,
      metadata_name,
      expected_uid,
      deadline_ns
    )
    return
  end
  if deadline_ns and uv.hrtime() >= deadline_ns then
    local diagnostic_id = diagnostic(diagnostics, "package_cache_timed_out", "The package cache deadline expired")
    table.insert(
      observations,
      observation(component, "cached", "timed_out", "owner-metadata-v1", nil, { diagnostic_id })
    )
    return
  end
  local names, scan_err = evidence.directory_entries(packages_root, packages_root, 64, expected_uid)
  if not names then
    if scan_err == "missing" then
      table.insert(observations, observation(component, "cached", "absent", "owner-metadata-v1"))
      return
    end
    local diagnostic_id = diagnostic(
      diagnostics,
      "package_cache_" .. tostring(scan_err),
      "The bounded OpenCode package cache could not be safely inspected"
    )
    table.insert(
      observations,
      observation(component, "cached", "unavailable", "owner-metadata-v1", nil, { diagnostic_id })
    )
    return
  end
  if deadline_ns and uv.hrtime() >= deadline_ns then
    local diagnostic_id = diagnostic(diagnostics, "package_cache_timed_out", "The package cache deadline expired")
    table.insert(
      observations,
      observation(component, "cached", "timed_out", "owner-metadata-v1", nil, { diagnostic_id })
    )
    return
  end
  local candidates = {}
  local matched = false
  local visited = 0
  local function visit_package_cache(path)
    if deadline_ns and uv.hrtime() >= deadline_ns then
      return nil, "timed_out"
    end
    visited = visited + 1
    if visited > 64 then
      return nil, "oversized"
    end
    local safe, safe_err = evidence.safe_snapshot(path, packages_root, expected_uid, "directory")
    if not safe then
      return nil, safe_err
    end
    local package_root = vim.fs.joinpath(path, "node_modules", component)
    if uv.fs_lstat(package_root) then
      local package_safe, package_err = evidence.safe_snapshot(package_root, path, expected_uid, "directory")
      if not package_safe then
        return nil, package_err
      end
      table.insert(candidates, package_root)
    end
    local children, children_err = evidence.directory_entries(path, packages_root, 64, expected_uid)
    if not children then
      return nil, children_err
    end
    for _, name in ipairs(children) do
      if name ~= "node_modules" then
        local child = vim.fs.joinpath(path, name)
        local stat = uv.fs_lstat(child)
        if stat and stat.type == "directory" then
          local ok, err = visit_package_cache(child)
          if not ok then
            return nil, err
          end
        elseif stat and stat.type == "link" then
          return nil, "unsafe"
        end
      end
    end
    return true
  end
  for _, name in ipairs(names) do
    if name == component or name:sub(1, #component + 1) == component .. "@" then
      matched = true
      local package_cache = vim.fs.joinpath(packages_root, name)
      local ok, cache_err = visit_package_cache(package_cache)
      if not ok then
        local diagnostic_id = diagnostic(
          diagnostics,
          "package_cache_" .. tostring(cache_err),
          "An allowlisted OpenCode package cache entry is incomplete or unsafe"
        )
        table.insert(
          observations,
          observation(
            component,
            "cached",
            cache_err == "timed_out" and "timed_out" or "unavailable",
            "owner-metadata-v1",
            nil,
            { diagnostic_id }
          )
        )
        return
      end
    end
  end
  if #candidates == 0 then
    if not matched then
      table.insert(observations, observation(component, "cached", "absent", "owner-metadata-v1"))
      return
    end
    local diagnostic_id = diagnostic(
      diagnostics,
      "package_cache_invalid",
      "An allowlisted OpenCode package cache entry does not contain the expected package"
    )
    table.insert(
      observations,
      observation(component, "cached", "unavailable", "owner-metadata-v1", nil, { diagnostic_id })
    )
    return
  end
  if #candidates > 1 then
    local diagnostic_id = diagnostic(
      diagnostics,
      "package_cache_ambiguous",
      "Multiple allowlisted OpenCode cache roots prevent a unique cached identity"
    )
    table.insert(
      observations,
      observation(component, "cached", "unavailable", "owner-metadata-v1", nil, { diagnostic_id })
    )
    return
  end
  installed_package(
    observations,
    declarations,
    diagnostics,
    component,
    "cached",
    candidates[1],
    metadata_name,
    expected_uid,
    deadline_ns
  )
end

installed_package = function(
  observations,
  declarations,
  diagnostics,
  component,
  layer,
  root,
  metadata_name,
  expected_uid,
  deadline_ns
)
  if not root then
    table.insert(observations, observation(component, layer, "not_discoverable", "fixed-package-root-v1"))
    return
  end
  local root_stat = uv.fs_lstat(root)
  if not root_stat then
    table.insert(observations, observation(component, layer, "absent", "owner-metadata-v1"))
    return
  end
  local metadata, err, diagnostic_id =
    read_owner(vim.fs.joinpath(root, metadata_name), root, component, expected_uid, diagnostics, deadline_ns)
  local state = metadata and "present" or err == "timed_out" and "timed_out" or "unavailable"
  if err == "missing" then
    diagnostic_id = diagnostic(
      diagnostics,
      "owner_metadata_unavailable",
      "An installed package is missing its required owner metadata"
    )
  end
  local extra = { version = metadata and metadata.component_version }
  if metadata and metadata.identity_profile then
    local digest, digest_err = evidence.digest_profile(root, metadata.identity_profile, expected_uid, deadline_ns)
    if digest then
      extra.identity_kind = metadata.identity_profile.id
      extra.identity = digest
      if metadata.identity_profile.sha256 and metadata.identity_profile.sha256 ~= digest then
        state = "unavailable"
        extra.identity_kind = nil
        extra.identity = nil
        diagnostic_id = diagnostic(
          diagnostics,
          "content_identity_mismatch",
          "Package content differs from its owner-declared immutable identity"
        )
      end
    else
      state = digest_err == "timed_out" and "timed_out" or "unavailable"
      diagnostic_id = diagnostic(
        diagnostics,
        "content_identity_" .. tostring(digest_err),
        "Package content identity could not be safely calculated"
      )
    end
  end
  table.insert(
    observations,
    observation(component, layer, state, "owner-metadata-v1", extra, diagnostic_id and { diagnostic_id } or {})
  )
  if metadata then
    declarations[component .. ":" .. layer] = metadata
  end
end

local function git_observation(observations, diagnostics, component, layer, result, evidence, owner_metadata)
  local state = probe_state(result)
  local identity
  local dirty
  if state == "present" then
    local line = result.stdout
      and (result.stdout:match "^([0-9a-f]+)%-dirty[\r\n]*$" or result.stdout:match "^([0-9a-f]+)[\r\n]*$")
    identity = line and #line == 40 and line or nil
    dirty = result.stdout and result.stdout:find "%-dirty[\r\n]*$" ~= nil or false
    if not identity then
      state = "unavailable"
    end
  end
  if state == "absent" and component == "mkchad" then
    state = "present"
  end
  local diagnostic_ids = {}
  if state == "unavailable" or state == "timed_out" then
    local id = diagnostic(diagnostics, "git_identity_unavailable", "Git content identity could not be proven")
    if id then
      table.insert(diagnostic_ids, id)
    end
  end
  table.insert(
    observations,
    observation(component, layer, state, evidence, {
      version = owner_metadata and owner_metadata.component_version,
      identity_kind = identity and "git-commit-v1" or nil,
      identity = identity,
      dirty = identity and dirty or nil,
    }, diagnostic_ids)
  )
end

local function target_for(observations, component, relationship_type)
  local preferred = relationship_type == "ships" and { "selected", "installed", "shipped" }
    or { "running", "selected", "installed", "shipped" }
  local fallback
  for _, layer in ipairs(preferred) do
    for _, item in ipairs(observations) do
      if item.component_id == component and item.layer == layer then
        if relationship_type == "ships" or item.state == "present" then
          return item
        end
        fallback = fallback or item
      end
    end
  end
  return fallback
end

local function component_list(observations)
  local components = {}
  for _, component_id in ipairs(inventory.component_ids) do
    local disposition = "absent"
    for _, item in ipairs(observations) do
      if item.component_id == component_id then
        if item.state == "present" then
          disposition = "present"
          break
        elseif disposition == "absent" and (item.state == "unavailable" or item.state == "timed_out") then
          disposition = "unavailable"
        elseif disposition == "absent" and item.state == "not_discoverable" then
          disposition = "not_discoverable"
        end
      end
    end
    table.insert(
      components,
      { id = component_id, optional = optional[component_id] or false, disposition = disposition }
    )
  end
  return components
end

local function build(options, probes)
  options = options or {}
  probes = probes or {}
  local diagnostics, observations, relationships, declarations = {}, {}, {}, {}
  if options.internal_error then
    diagnostic(diagnostics, "collector_internal_error", "Component collection failed closed before model publication")
  end
  local paths = default_paths(options)
  local user_uid = assert(uv.getuid and uv.getuid(), "effective uid is unavailable")
  local image_uid = options.image_uid or 0
  local host, host_err = host_transport.decode(options.host_evidence)
  local host_diagnostic
  if host_err == "omitted" then
    host = {}
  elseif not host then
    host = {}
    host_diagnostic = diagnostic(diagnostics, "host_evidence_invalid", "Host evidence was unavailable")
  end
  local function host_observation(component, layer, item, evidence)
    if host_err == "omitted" then
      table.insert(observations, observation(component, layer, "not_discoverable", evidence))
      return
    end
    if not item then
      table.insert(
        observations,
        observation(component, layer, "unavailable", evidence, nil, host_diagnostic and { host_diagnostic } or {})
      )
      return
    end
    local extra = item.state == "present"
        and {
          version = item.version,
          identity_kind = item.identity_kind or item.executable_identity_kind,
          identity = item.identity or item.executable_identity,
          label = item.label,
          runtime_family = item.family,
        }
      or nil
    table.insert(observations, observation(component, layer, item.state, evidence, extra))
  end
  host_observation("container-runtime", "installed", host.container_runtime, "host-runtime-v1")
  host_observation("nvim-image", "selected", host.selected_image, "host-image-v1")
  host_observation("nvim-image", "persisted", host.persisted_instance, "host-instance-v1")

  table.insert(observations, observation("mkchad", "declared", "present", "mkchad-contract-v1"))
  declarations["mkchad:declared"] = contracts
  table.insert(
    observations,
    observation("opencode-nvim", "declared", "present", "mkchad-plugin-revision-v1", {
      identity_kind = "git-commit-v1",
      identity = contracts.opencode_nvim_revision,
    })
  )
  git_observation(observations, diagnostics, "mkchad", "installed", probes.mkchad_git, "git-checkout-v1")

  local image, image_err, image_diagnostic =
    read_owner(paths.image_manifest, paths.image_root, "nvim-image", image_uid, diagnostics, options.deadline_ns)
  if image_err == "missing" then
    image_diagnostic = diagnostic(diagnostics, "image_manifest_unavailable", "Image component metadata is unavailable")
  end
  table.insert(
    observations,
    observation(
      "nvim-image",
      "shipped",
      image and "present" or image_err == "timed_out" and "timed_out" or "unavailable",
      "image-manifest-v1",
      image and { identity_kind = "image-build-id-v1", identity = image.build_id } or nil,
      image_diagnostic and { image_diagnostic } or {}
    )
  )
  if image then
    declarations["nvim-image:shipped"] = image
    local shipped = {}
    for _, relation in ipairs(image.relationships) do
      local contract = relation.contract
      shipped[relation.target_component] = true
      table.insert(
        observations,
        observation(relation.target_component, "shipped", "present", "image-manifest-v1", {
          version = contract.version,
          identity_kind = contract.kind == "identity" and contract.profile or nil,
        })
      )
    end
    for _, component in ipairs { "opencode", "prereq-neovim", "prereq-node" } do
      if not shipped[component] then
        table.insert(observations, observation(component, "shipped", "unavailable", "image-manifest-v1"))
      end
    end
  else
    for _, component in ipairs { "opencode", "prereq-neovim", "prereq-node" } do
      table.insert(observations, observation(component, "shipped", "unavailable", "image-manifest-v1"))
    end
  end

  local plugin_metadata, plugin_metadata_error = read_owner(
    vim.fs.joinpath(paths.opencode_nvim, "opencode-component.json"),
    paths.opencode_nvim,
    "opencode-nvim",
    user_uid,
    diagnostics,
    options.deadline_ns
  )
  git_observation(
    observations,
    diagnostics,
    "opencode-nvim",
    "installed",
    probes.opencode_nvim_git,
    "lazy-git-checkout-v1",
    plugin_metadata
  )
  if plugin_metadata_error == "missing" and probe_state(probes.opencode_nvim_git) == "present" then
    diagnostic(diagnostics, "owner_metadata_unavailable", "Installed opencode.nvim metadata is unavailable")
  end
  if plugin_metadata then
    declarations["opencode-nvim:installed"] = plugin_metadata
  end
  table.insert(observations, observation("opencode-nvim", "loaded", "unprovable", "owner-attestation-v1"))

  installed_package(
    observations,
    declarations,
    diagnostics,
    "opencode-project-reload",
    "installed",
    paths.project_installed,
    "opencode-component.json",
    user_uid,
    options.deadline_ns
  )
  cached_package(
    observations,
    declarations,
    diagnostics,
    "opencode-project-reload",
    paths.cache_packages,
    options.project_cached_root,
    "opencode-component.json",
    user_uid,
    options.deadline_ns
  )
  table.insert(observations, observation("opencode-project-reload", "loaded", "unprovable", "owner-attestation-v1"))
  installed_package(
    observations,
    declarations,
    diagnostics,
    "compound-engineering",
    "installed",
    paths.ce_installed,
    "component.json",
    user_uid,
    options.deadline_ns
  )
  cached_package(
    observations,
    declarations,
    diagnostics,
    "compound-engineering",
    paths.cache_packages,
    options.ce_cached_root,
    "component.json",
    user_uid,
    options.deadline_ns
  )
  table.insert(observations, observation("compound-engineering", "loaded", "unprovable", "owner-attestation-v1"))

  local selected_state = probe_state(probes.opencode)
  local selected_version = parse_version(probes.opencode, "^v?([0-9][0-9A-Za-z.+_-]*)$")
  if selected_state == "present" and not selected_version then
    selected_state = "unavailable"
  end
  local selected_diagnostics = {}
  if selected_state == "unavailable" or selected_state == "timed_out" then
    local id = diagnostic(
      diagnostics,
      selected_state == "timed_out" and "probe_timed_out" or "probe_unavailable",
      "The selected OpenCode executable did not return valid version evidence"
    )
    if id then
      table.insert(selected_diagnostics, id)
    end
  end
  table.insert(
    observations,
    observation("opencode", "selected", selected_state, "selected-executable-v1", {
      version = selected_version,
      identity_kind = probes.opencode and probes.opencode.path and "image-file-stat-v1" or nil,
      identity = probes.opencode and probes.opencode.path and executable_identity(probes.opencode.path) or nil,
    }, selected_diagnostics)
  )
  local lifecycle = options.lifecycle or {}
  table.insert(
    observations,
    observation("opencode", "persisted", lifecycle.persisted_state or "not_discoverable", "lifecycle-projection-v1", {
      version = lifecycle.persisted_version,
      identity_kind = lifecycle.persisted_identity_kind,
      identity = lifecycle.persisted_identity,
    })
  )
  table.insert(
    observations,
    observation("opencode", "running", lifecycle.running_state or "not_discoverable", "lifecycle-projection-v1", {
      version = lifecycle.running_version,
      identity_kind = lifecycle.running_identity_kind,
      identity = lifecycle.running_identity,
    })
  )
  local versions = {}
  for _, item in ipairs(observations) do
    if item.component_id == "opencode" and item.state == "present" and item.version then
      versions[item.version] = true
    end
  end
  local distinct_versions = 0
  for _ in pairs(versions) do
    distinct_versions = distinct_versions + 1
  end
  if distinct_versions > 1 then
    diagnostic(
      diagnostics,
      "opencode_layer_drift",
      "Selected, persisted, or running OpenCode versions differ across observed layers"
    )
  end

  local controller_state = probe_state(probes.sprint_loop)
  local controller
  if controller_state == "present" then
    local decoded = inventory.decode_json(probes.sprint_loop.stdout or "", owner_limit)
    if decoded and type(decoded) == "table" and type(decoded.supported_opencode) == "table" then
      controller = inventory.validate_owner({
        schema = decoded.schema,
        component_id = decoded.component_id,
        component_version = decoded.controller_version,
        relationships = { decoded.supported_opencode },
        identity_profile = decoded.identity_profile,
      }, "sprint-loop-controller")
    end
    if not controller then
      controller_state = "unavailable"
    end
  end
  local controller_diagnostics = {}
  if controller_state == "unavailable" or controller_state == "timed_out" then
    local id = diagnostic(
      diagnostics,
      controller_state == "timed_out" and "probe_timed_out" or "probe_unavailable",
      "Sprint-loop component identity could not be safely collected"
    )
    if id then
      table.insert(controller_diagnostics, id)
    end
  end
  table.insert(
    observations,
    observation("sprint-loop-controller", "installed", controller_state, "component-info-v1", {
      version = controller and controller.component_version,
    }, controller_diagnostics)
  )
  if controller then
    declarations["sprint-loop-controller:installed"] = controller
  end
  git_observation(
    observations,
    diagnostics,
    "sprint-loop-nvim",
    "installed",
    probes.sprint_nvim_git,
    "lazy-git-checkout-v1"
  )
  table.insert(observations, observation("sprint-loop-nvim", "loaded", "unprovable", "owner-attestation-v1"))

  table.insert(
    observations,
    observation("prereq-neovim", "installed", "present", "current-process-v1", {
      version = table.concat({ vim.version().major, vim.version().minor, vim.version().patch }, "."),
    })
  )
  add_probe_observation(
    observations,
    diagnostics,
    "prereq-git",
    probes.git,
    "exact-version-probe-v1",
    "^git version ([^ ]+)$"
  )
  add_probe_observation(
    observations,
    diagnostics,
    "prereq-python",
    probes.python,
    "exact-version-probe-v1",
    "^Python ([^ ]+)$"
  )
  add_probe_observation(observations, diagnostics, "prereq-node", probes.node, "exact-version-probe-v1", "^v([^ ]+)$")
  add_probe_observation(
    observations,
    diagnostics,
    "prereq-curl",
    probes.curl,
    "exact-version-probe-v1",
    "^curl ([^ ]+)",
    nil,
    true
  )

  local by_id = {}
  for _, item in ipairs(observations) do
    by_id[item.id] = item
  end
  for _, component in ipairs { "opencode-project-reload", "compound-engineering" } do
    local installed_id, cached_id = component .. ":installed", component .. ":cached"
    local installed, cached = declarations[installed_id], declarations[cached_id]
    if installed and cached then
      if not vim.deep_equal(installed.relationships, cached.relationships) then
        diagnostic(
          diagnostics,
          "owner_contract_mismatch",
          "Installed and cached owner compatibility declarations disagree"
        )
      end
      declarations[cached_id] = nil
    end
  end
  for _, source_id in ipairs {
    "mkchad:declared",
    "nvim-image:shipped",
    "opencode-nvim:installed",
    "opencode-project-reload:installed",
    "opencode-project-reload:cached",
    "compound-engineering:installed",
    "compound-engineering:cached",
    "sprint-loop-controller:installed",
  } do
    local metadata = declarations[source_id]
    if metadata then
      for _, declaration in ipairs(metadata.relationships) do
        local target = target_for(observations, declaration.target_component, declaration.type)
        local relationship_source_id = source_id == "mkchad:declared" and "opencode-nvim:declared" or source_id
        table.insert(relationships, {
          id = source_id .. ":" .. declaration.id,
          type = declaration.type,
          owner = metadata.component_id,
          source_observation_id = relationship_source_id,
          target_observation_id = target and target.id or nil,
          contract = declaration.contract,
          result = inventory.evaluate(declaration, by_id[relationship_source_id], target),
          diagnostic_ids = {},
        })
      end
    end
  end
  for _, pair in ipairs {
    { "opencode-nvim:loaded", "opencode-nvim:installed", "opencode-nvim", "git-commit-v1" },
    {
      "opencode-project-reload:installed",
      "opencode-project-reload:cached",
      "opencode-project-reload",
      "opencode-project-reload-tui-v1",
    },
    {
      "compound-engineering:installed",
      "compound-engineering:cached",
      "compound-engineering",
      "compound-engineering-plugin-v1",
    },
    { "sprint-loop-nvim:loaded", "sprint-loop-nvim:installed", "sprint-loop-nvim", "git-commit-v1" },
  } do
    local source_observation, target_observation = by_id[pair[1]], by_id[pair[2]]
    local relation = {
      id = pair[3] .. ":loaded-from",
      type = "loaded-from",
      owner = pair[3],
      source_observation_id = pair[1],
      target_observation_id = pair[2],
      contract = { kind = "identity", profile = pair[4] },
      diagnostic_ids = {},
    }
    relation.result = inventory.evaluate(relation, source_observation, target_observation)
    table.insert(relationships, relation)
  end

  return inventory.model(component_list(observations), observations, relationships, diagnostics)
end

function M.collect(options)
  options = options or {}
  return build(options, options.probe_results)
end

function M.fallback(lifecycle)
  return build({ lifecycle = lifecycle or {}, fallback = true, internal_error = true }, {})
end

local function executable(path, roots)
  if not path or path == "" then
    return nil
  end
  local resolved = uv.fs_realpath(path)
  local stat = resolved and uv.fs_stat(resolved)
  if not stat or stat.type ~= "file" or bit.band(stat.mode, 73) == 0 or bit.band(stat.mode, 18) ~= 0 then
    return nil
  end
  local trusted = false
  for _, root in ipairs(roots) do
    if
      evidence.path_within(resolved, root.path)
      and stat.uid == root.uid
      and evidence.validate_ancestors(root.path, resolved, root.uid)
    then
      trusted = true
      break
    end
  end
  if not trusted then
    return nil
  end
  return resolved
end

local function probe_specs(options)
  local paths = default_paths(options)
  local executables = options.executables or {}
  local user_uid = assert(uv.getuid and uv.getuid(), "effective uid is unavailable")
  local roots = {
    { path = "/usr", uid = 0 },
    { path = "/bin", uid = 0 },
  }
  local npm_root = options.npm_root or vim.env.MSK_NPM_GLOBAL_ROOT
  if npm_root then
    table.insert(roots, { path = npm_root, uid = user_uid })
  end
  for _, root in ipairs(options.trusted_executable_roots or {}) do
    table.insert(roots, { path = root, uid = user_uid })
  end
  local function selected(name, fallback)
    if executables[name] == false then
      return nil
    end
    return executable(executables[name] or vim.fn.exepath(fallback or name), roots)
  end
  local git = selected "git"
  local function git_spec(root, allowed_root)
    if not root then
      return { missing = true }
    end
    local root_snapshot, root_err = evidence.safe_snapshot(root, allowed_root, user_uid, "directory")
    if not root_snapshot then
      return root_err == "missing" and { missing = true } or { invalid = true }
    end
    local git_path = vim.fs.joinpath(root, ".git")
    local git_snapshot, git_err = evidence.safe_snapshot(git_path, root, user_uid, "directory")
    if not git_snapshot then
      return git_err == "missing" and { missing = true } or { invalid = true }
    end
    if not git then
      return { missing = true }
    end
    return {
      argv = {
        git,
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "--no-optional-locks",
        "-C",
        root,
        "describe",
        "--always",
        "--dirty",
        "--abbrev=40",
        "--match=__mkchad_no_tag_can_match__",
      },
      validate = function()
        return evidence.snapshot_unchanged(root, root_snapshot) and evidence.snapshot_unchanged(git_path, git_snapshot)
      end,
    }
  end
  local opencode = selected "opencode"
  local sprint_loop = selected("sprint_loop", "sprint-loop")
  local python = selected("python", "python3")
  local node = selected "node"
  local curl = selected "curl"
  return {
    mkchad_git = git_spec(options.config_root, options.config_root),
    opencode_nvim_git = git_spec(paths.opencode_nvim, paths.lazy_root),
    sprint_nvim_git = git_spec(paths.sprint_nvim, paths.lazy_root),
    opencode = opencode and { argv = { opencode, "--version" }, path = opencode } or { missing = true },
    sprint_loop = sprint_loop and { argv = { sprint_loop, "component-info", "--json" } } or { missing = true },
    git = git and { argv = { git, "--version" } } or { missing = true },
    python = python and { argv = { python, "--version" } } or { missing = true },
    node = node and { argv = { node, "--version" } } or { missing = true },
    curl = curl and { argv = { curl, "--version" } } or { missing = true },
  }
end

function M.collect_async(options, callback)
  assert(type(callback) == "function")
  options = options or {}
  local probe = assert(options.probe, "inventory collector requires a bounded probe runner")
  local results, pending, lifecycle, probes_done, completed = {}, 0, nil, false, false
  local launching = true
  local collected
  local collecting = false
  local deadline_ns = uv.hrtime() + 4000 * 1000000
  options.deadline_ns = deadline_ns
  local specs = probe_specs(options)
  local function apply_lifecycle(model)
    local observations = vim.deepcopy(model.observations)
    local diagnostics = {}
    for _, item in ipairs(model.diagnostics) do
      if item.code ~= "opencode_layer_drift" then
        table.insert(diagnostics, vim.deepcopy(item))
      end
    end
    local by_id = {}
    for _, item in ipairs(observations) do
      by_id[item.id] = item
    end
    local persisted, running = by_id["opencode:persisted"], by_id["opencode:running"]
    persisted.state = lifecycle.persisted_state or "not_discoverable"
    persisted.version = lifecycle.persisted_version
    persisted.identity_kind = lifecycle.persisted_identity_kind
    persisted.identity = lifecycle.persisted_identity
    running.state = lifecycle.running_state or "not_discoverable"
    running.version = lifecycle.running_version
    running.identity_kind = lifecycle.running_identity_kind
    running.identity = lifecycle.running_identity
    local versions = {}
    for _, item in ipairs(observations) do
      if item.component_id == "opencode" and item.state == "present" and item.version then
        versions[item.version] = true
      end
    end
    local distinct = 0
    for _ in pairs(versions) do
      distinct = distinct + 1
    end
    if distinct > 1 then
      diagnostic(
        diagnostics,
        "opencode_layer_drift",
        "Selected, persisted, or running OpenCode versions differ across observed layers"
      )
    end
    local relationships = vim.deepcopy(model.relationships)
    for _, relationship in ipairs(relationships) do
      local previous_target = by_id[relationship.target_observation_id]
      local target = previous_target
      if previous_target and previous_target.component_id == "opencode" then
        target = target_for(observations, previous_target.component_id, relationship.type)
      end
      relationship.target_observation_id = target and target.id or nil
      relationship.result = inventory.evaluate(relationship, by_id[relationship.source_observation_id], target)
    end
    return inventory.model(component_list(observations), observations, relationships, diagnostics)
  end
  local function maybe_finish()
    if completed or not collected or lifecycle == nil then
      return
    end
    completed = true
    local ok, model = pcall(apply_lifecycle, collected)
    if ok then
      callback(model)
      return
    end
    callback(M.fallback(lifecycle))
  end
  local function maybe_collect()
    if collecting or not probes_done then
      return
    end
    collecting = true
    vim.schedule(function()
      local build_options = vim.tbl_extend("force", {}, options, {
        lifecycle = { persisted_state = "unqueried", running_state = "unqueried" },
      })
      local ok, model = pcall(build, build_options, results)
      collected = ok and model or M.fallback(build_options.lifecycle)
      maybe_finish()
    end)
  end
  for id, spec in pairs(specs) do
    if spec.missing then
      results[id] = { missing = true }
    elseif spec.invalid then
      results[id] = { error = true }
    else
      pending = pending + 1
      probe(spec.argv, {
        timeout_ms = 2000,
        deadline_ns = deadline_ns,
        cwd = "/",
        replace_env = true,
        process_group = true,
        output_limit = 4096,
        env = {
          HOME = "/nonexistent",
          XDG_CONFIG_HOME = "/nonexistent",
          XDG_DATA_HOME = "/nonexistent",
          XDG_CACHE_HOME = "/nonexistent",
          GIT_CONFIG_NOSYSTEM = "1",
          GIT_OPTIONAL_LOCKS = "0",
          LC_ALL = "C",
          PATH = "/usr/bin:/bin",
        },
      }, function(result, err)
        results[id] = spec.validate and not spec.validate() and { error = true, raced = true }
          or result
          or { error = true }
        results[id].error = err ~= nil
        results[id].path = spec.path
        pending = pending - 1
        if pending == 0 and not launching then
          probes_done = true
          maybe_collect()
        end
      end)
    end
  end
  launching = false
  if pending == 0 then
    probes_done = true
  end
  maybe_collect()
  return function(projection)
    lifecycle = projection or {}
    maybe_finish()
  end
end

return M

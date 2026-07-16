**This repo is supposed to used as config by NvChad users!**

- The main nvchad repo (NvChad/NvChad) is used as a plugin by this repo.
- So you just import its modules , like `require "nvchad.options" , require "nvchad.mappings"`
- So you can delete the .git from this repo ( when you clone it locally ) or fork it :)

## OpenCode shared server

### Standalone lifecycle command

After installing the Neovim container tools, use the active `neovim.sif` from
an ordinary shell to manage the shared detached service without opening MkChad:

```text
mkchad-opencode-server start [--json]
mkchad-opencode-server status [--json]
mkchad-opencode-server stop [--json]
```

The command is installed as `~/.local/bin/mkchad-opencode-server` by
`msk_containers/bin/install_nvim.sh`. It requires the installed MkChad lifecycle
assets, the active `${NVIM_CONTAINER_DIR:-$HOME/containers}/neovim.sif` (or the
supported `NVIM_CONT_LOCATION` override), and SingularityCE or Apptainer when
run from the host. It uses minimal `nvim -u NONE` execution inside that image;
it does not load `init.lua`, plugins, an attached OpenCode TUI, or a MkChad UI.
There is no host-native OpenCode fallback.

`start` reuses a fully validated generation or performs the bounded reviewed
recovery flow. `status` is observational: it reports `healthy`, `inactive`,
`unhealthy`, or `blocked` without starting, stopping, repairing, or creating
lifecycle state. `stop` follows validated active state rather than the current
transport setting and is an idempotent success when no managed service is
active. Usage errors exit `2`; refused or failed start/stop operations exit `1`;
completed operations, including observational unhealthy or blocked status, exit
`0`.

With `--json`, stdout contains exactly one versioned JSON result and newline.
Successful healthy results contain only `url`, `transport`, `generation`, and
the active `ca_cert` (or JSON `null` in direct mode); they never contain
credentials or config contents. Keep wrapper/runtime diagnostics on stderr.
If the runtime, active image, or lifecycle asset is missing, correct that
installation issue before retrying; do not bypass the managed state with a
host-native server.

OpenCode starts lazily: ordinary MkChad startup and `:OpenCodeInfo` do not
create a server. The first OpenCode action starts one detached loopback-only
server and attaches a local TUI for the current Neovim directory. The default
is the hardened TLS profile:

```text
clients -> HTTPS 127.0.0.1:<public port> -> Java TLS proxy -> HTTP OpenCode backend on an internal port
```

An explicit trusted-host opt-out (`"tls_proxy": false`) instead uses:

```text
clients -> HTTP 127.0.0.1:<public port> -> OpenCode backend
```

`:OpenCodeInfo` reports the persisted URL and fresh transport-appropriate
health without changing lifecycle state.

> **Multi-user host warning:** TLS authenticates the server to clients; it does
> not authenticate clients and possession of `ca.pem` does not control access.
> Without a user-supplied password in protected `opencode-server.json` or
> `OPENCODE_SERVER_PASSWORD`, both the public TLS proxy and the discoverable
> internal loopback HTTP backend accept requests from other local users. Set a
> strong existing password before first use. If the pair is already running,
> set the password, run `:OpenCodeStop`, restart Neovim when the file changed,
> and start OpenCode again so both endpoints enforce it.

> **Direct HTTP warning:** Direct mode is only for a host where every relevant
> same-host user and process is trusted, or where the owner explicitly accepts
> their plaintext-loopback and replacement-listener capability. It has no CA
> server identity, proxy tuple proof, or stale-client protection after backend
> death. Basic Auth can reject unauthenticated requests but does not encrypt its
> header. An SSH tunnel does not restore host-local endpoint identity after it
> terminates.

State lives in `${XDG_STATE_HOME:-$HOME/.local/state}/mkchad/opencode/<host>/`:
`state.json`, `server.log`, `proxy.log`, a startup lock, and `tls/`. The
directory and `tls/` are mode `0700`; state, logs, CA, PKCS12 stores, and the
random keytool password file are mode `0600`. The password value is passed to
keytool with `-storepass:file` and is never placed in argv, state, logs, or
notifications. Schema-3 state records its `tls-proxy` or `loopback-http`
transport plus immutable runtime executable device/inode,
launch executable device/inode, exact argv, PID start time, boot identity, and
listener information for each managed process. The Java source launcher also
records the proxy source device/inode.

Before each process spawn, MkChad records a generation-specific `launch.json`
intent. Successful immutable identity capture transfers authority to
`pending.json`; an unresolved intent blocks later starts so a cleanup-refused
process cannot be multiplied. Remove an unresolved intent only after trusted OS
process accounting confirms its recorded role is dead.

The proxy completes TLS first, opens one backend connection, sends only a fixed
unauthenticated `GET /global/health`, and proves the exact reverse established
tuple's socket inode belongs to the recorded backend PID before reading or
forwarding client HTTP bytes. It never reconnects a client stream. Loss of the
proxy, backend, listener, process identity, certificate identity, or pinned
health replaces both processes under the renewable lifecycle lock.

MkChad reads optional server settings from
`${XDG_CONFIG_HOME:-$HOME/.config}/mkchad/opencode-server.json` when the
OpenCode plugin first loads. The file is ignored by Git because it may contain
a password, and MkChad refuses it unless it is a current-user-owned regular
file with mode `0600`. The supported keys are:

```json
{
  "port": 4096,
  "username": "opencode",
  "password": "a-strong-existing-password",
  "tls_proxy": true
}
```

See `opencode-server.example.json` for a template. Non-empty
`OPENCODE_PORT`, `OPENCODE_SERVER_USERNAME`, and `OPENCODE_SERVER_PASSWORD`
environment variables override the corresponding file values. `tls_proxy`
accepts only JSON `true` or `false`, defaults to `true` when absent, and has no
environment override. Settings are process-cached: restart Neovim after changing
the file. If a shared server is already running, use `:OpenCodeStop` before
starting it again so port, authentication, or transport changes take effect.
MkChad refuses an opposite requested/active transport rather than replacing it;
stop it, restart Neovim, and start again to make a transport transition.

Without a configured port, the server prefers port `4096` and persists a high
fallback port when `4096` is occupied. A port set by the config file or
`OPENCODE_PORT` is used exactly. `:OpenCodeStart` refuses to launch when that
port is occupied and never selects a fallback. Use `:OpenCodeStop` (or
`:Opencode stop`) to stop the **shared** server, which affects other MkChad and
web clients.

TLS mode binds both ports to loopback. Direct mode binds its one public backend
port to loopback. Set the config-file password (and optional username), or the
corresponding environment variables, to enable OpenCode Basic Auth. On a
multi-user TLS host, a strong password remains required because the internal
backend port is discoverable and directly reachable.
Credentials sent by managed clients travel only inside CA-pinned TLS on the
public endpoint; the internal HTTP endpoint receives no managed client bytes
until the proxy proves ownership of that same established connection. This
relay proof does not prevent a local user from connecting directly to the
internal port.

In TLS mode the stable host CA is:

`${XDG_STATE_HOME:-$HOME/.local/state}/mkchad/opencode/<host>/tls/ca.pem`

`opencode attach` receives this path through `NODE_EXTRA_CA_CERTS`, and
opencode.nvim/curl receive it through protected stdin curl configuration.
Browsers are not configured automatically: import/trust this CA manually, then
open the exact HTTPS URL shown by `:OpenCodeInfo`. Keep the CA private to the
host account even though it is a certificate; its signing key remains in the
mode-0600 `ca.p12` store. The CA and public leaf remain stable across ordinary
backend recovery and rotate only when protected certificate material is absent
or invalid.
Direct mode neither creates nor validates TLS material; retained valid material
is inactive until TLS mode is selected again. Direct clients receive no CA
setting, and browser bookmarks change scheme between `https://` and `http://`.
After updating a mounted OpenCode runtime, inspect the version mismatch in
`:OpenCodeInfo`, run `:OpenCodeStop`, then use OpenCode again to launch the new
executable. Detached-child persistence depends on the SingularityCE/Apptainer
runtime; a killed proxy or backend is recovered on the next OpenCode operation.
When a TLS proxy dies, existing clients disconnect; `:OpenCodeInfo` remains
observational and reload does not restart it. The next ensuring action stops the
freshly verified surviving backend and replaces the TLS generation. `:OpenCodeStop`
performs that verified partial cleanup without starting a replacement. Multiple
attached TUIs using the same directory remain an OpenCode limitation.

Persisted schema-1 HTTP state is treated as legacy. Diagnostics label it and
never probe its URL with credentials. Live schema-1 processes are never
signalable because their records lack the immutable identity required by the
current lifecycle. Stop a live legacy process through trusted OS process
accounting; once it is dead, the next lifecycle operation removes its stale
state and creates a schema-3 generation.

Schema-2 state created before immutable executable device/inode fields were
added is malformed and is never used to signal a process. Recovery is bounded:
the next operation may create a new pair on free ports, or fail on a conflict.
Use process information from a trusted administrator to terminate any old pair
manually; do not delete pending metadata until its old processes are accounted
for.

Before downgrading MkChad, run `:OpenCodeStop` while the current version can
still validate and remove its schema-3 generation. Confirm that complete and
pending schema-3 metadata and `launch.json` are absent before starting an older
version, which must treat schema 3 as unsupported rather than mutating it.

`:OpenCodeReload` (or `:Opencode reload`) refreshes only the current absolute
directory instance. It refuses while that directory has active work, a pending
permission, or a pending question; it does not start an inactive server or
restart the shared server. It recreates this Neovim's attached TUI after the
instance refresh. Project-scoped OpenCode configuration can therefore refresh,
but process-cached global configuration still requires `:OpenCodeStop` followed
by the next OpenCode operation.

# Credits

1) Lazyvim starter https://github.com/LazyVim/starter as nvchad's starter was inspired by Lazyvim's . It made a lot of things easier!

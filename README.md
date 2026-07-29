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
mkchad-opencode-server clear [--json]
mkchad-opencode-server kill [--json]
```

The public host command is installed as `~/.local/bin/mkchad-opencode-server`
by `msk_containers/bin/install_nvim.sh`. It enters the active image through the
same profile-bound persistent SingularityCE/Apptainer contract as the MkChad
launcher, including configured container mounts, then delegates to the installed
`mkchad-opencode-server-image` companion. The instance retains image executables
and libraries after a short-lived manager or originating editor exits.
MkChad prefers that companion directly because it is already inside the image;
during a staggered upgrade it falls back to the public launcher's compatible
in-image route until the companion has been installed.
The commands require the installed MkChad lifecycle assets, the active
`${NVIM_CONTAINER_DIR:-$HOME/containers}/neovim.sif` (or the supported
`NVIM_CONT_LOCATION` override), and SingularityCE or Apptainer when run from the
host. They use minimal `nvim -u NONE` execution; they do not load `init.lua`,
plugins, an attached OpenCode TUI, or a MkChad UI. There is no host-native
OpenCode fallback.

MkChad uses the in-image companion asynchronously before it connects opencode.nvim.
It accepts only the current validated command result for its URL and TLS CA;
command failure leaves no plugin terminal-start fallback. `:OpenCodeStop` uses
the command and closes only that editor's local TUI after successful or inactive
stop. `:OpenCodeInfo` obtains its server status through the command while
reporting editor-local TUI and SSE presentation separately. When invoked from a
MkChad Neovim image, the wrapper recognizes the image/runtime marker and runs
that image's Neovim directly without nesting SingularityCE or Apptainer; its
MkChad XDG, npm, and `OPENCODE_CONFIG` environment remain in effect. Detached
`start` is refused inside an ordinary foreground container because its image
mount can disappear while the server is still running.

`start` reuses a fully validated generation or performs the bounded reviewed
recovery flow. `status` is observational: it reports `healthy`, `inactive`,
`unhealthy`, `stopping`, or `blocked` without starting, stopping, repairing, or
creating lifecycle state. `stop` follows validated active state rather than the current
transport setting and is an idempotent success when no managed service is
active. Usage errors exit `2`; refused or failed lifecycle operations exit `1`;
completed operations, including observational unhealthy or blocked status, exit
`0`.

Server `stop` leaves the idle runtime instance available for future MkChad and
lifecycle commands. It never maps a successful server stop to `instance stop`,
which could race another caller and kill a newly started generation or editor.
After stopping the server and accounting for all MkChad/container users, an
operator may list and stop the exact idle instance with the selected container
runtime. Image or bootstrap upgrades select a new instance profile rather than
silently reusing stale mounts.

`clear` is the explicit stale-authority reset for an operator who has already
accounted for any old processes. It removes this host lifecycle root's metadata,
control artifacts, logs, stale lock debris, and TLS material. It refuses when a
valid record proves a managed broker, proxy, or backend is live, but may remove
malformed or stale metadata because it never derives signal authority from it.
Unsupported future schemas and broker protocols remain protected authority and
must be handled by a compatible MkChad version.
It never deletes OpenCode sessions, authentication or credentials, XDG data, or
general XDG cache. `kill` first performs the strongest validated managed
shutdown available, including broker-owned schema-4 stop and direct TERM-to-KILL
escalation. It verifies every recorded role and schema-4 control authority is
absent before performing the same reset; a failed validation, shutdown, or live
recorded role preserves lifecycle authority for manual accounting. Both commands
are idempotent when inactive and serialize with lifecycle start and stop.

With `--json`, stdout contains exactly one versioned JSON result and newline.
Successful healthy results contain only `url`, `transport`, `generation`, the
live `server_version`, and the active `ca_cert` (or JSON `null` in direct mode);
they never contain credentials or config contents. Non-healthy observations may
include one bounded `diagnostic` object with a stable code and presentation
message. Keep wrapper/runtime diagnostics on stderr.
Without `--json`, `status` reports the shared `:OpenCodeInfo` fields available
outside the editor: command status, public URL, transport, generation, live
server version, active TLS CA, and any blocked or unhealthy lifecycle
diagnostic. Editor-local plugin SSE and attached-TUI state remain exclusive to
`:OpenCodeInfo`.
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
`state.json`, `pending.json`, `launch.json`, `control.sock`, `server.log`,
`proxy.log`, a startup lock, and `tls/`. The directory and `tls/` are mode
`0700`; state, logs, TLS files, lock metadata, and broker-created control files
are current-user-only. The password value is passed to keytool with
`-storepass:file` and is never placed in argv, state, logs, or notifications.

New TLS generations use schema 4. They record the broker protocol, protected
control-socket path and device/inode, plus immutable runtime and launch
executable identity, exact argv, PID start time, boot identity, listener proof,
and certificate identity for the broker and backend. Direct HTTP remains schema
3. Schema 2 and schema 3 TLS records remain supported by their existing exact
proof route; MkChad does not silently rewrite a healthy pre-broker generation.
State paths and PIDs are evidence, not authority by themselves: MkChad also
requires current-user private path checks and exact process, boot, executable,
argv, listener, certificate, and control-socket evidence before it uses a
recorded generation.

Before each process spawn, MkChad records a generation-specific `launch.json`
intent. A TLS broker first publishes control-ready schema-4 `pending.json`, then
commits backend activation and finally complete state. The broker owns backend
creation and committed stop after the control request is accepted; Lua owns the
kernel fence and metadata publication/removal. Its private protocol accepts one
bounded request on the recorded socket and exposes `control-ready`, `activating`,
`running`, `unhealthy`, `activation-failed`, `stopping`, `stopped`, or `blocked`
status. The nonce correlates a response but is not authorization. The socket is
not a public lifecycle API and must remain inside the protected state root.

Concurrent starts serialize through the lifecycle fence and logical lock. A
losing caller waits only for a fully validated winning generation and never
activates another backend or sends a duplicate lifecycle signal. An unresolved
intent or pending record that cannot be proved remains blocking authority rather
than a candidate for replacement.

The proxy completes TLS first, opens one backend connection, sends only a fixed
unauthenticated `GET /global/health`, and proves the exact reverse established
tuple's socket inode belongs to the recorded backend PID before reading or
forwarding client HTTP bytes. It never reconnects a client stream. For schema-4
TLS, a live broker with a dead backend is unhealthy and may be cleaned only by a
committed broker stop; a dead broker with a live backend is blocked for manual
operating-system accounting; both dead roles may be reconciled only after the
recorded control inode is safely accounted for. Loss of the public broker drops
existing streams. Status and reload remain observational and never restart it.

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
state and creates a schema-4 TLS generation (or schema-3 direct generation).

Schema-2 state created before immutable executable device/inode fields were
added is malformed and is never used to signal a process. Recovery is bounded:
the next operation may create a new pair on free ports, or fail on a conflict.
Use process information from a trusted administrator to terminate any old pair
manually; do not delete pending metadata until its old processes are accounted
for.

Before downgrading MkChad, run `:OpenCodeStop` while the current version can
still validate and remove its schema-4 broker generation. A committed broker
stop first closes public admission and registered relays, then stops its backend,
removes the matching control socket, returns its terminal receipt, and exits.
Lua removes matching metadata only after that receipt, broker termination, and
control-path absence. If the receipt is lost, state is deliberately preserved
until later fenced reconciliation proves the broker, backend, and recorded
control path are absent. Do not delete it to force a replacement.

Confirm that complete state, pending metadata, and `launch.json` are absent
before starting a reviewed pre-broker version. Older launchers must preserve
schema-4 complete, pending, and broker-launch bytes and must not signal their
recorded processes. On upgrade, current MkChad continues to validate restricted
schema-2/3 state through its legacy proof route; stop a healthy old TLS
generation before starting again to move to schema 4. Retained valid certificate
material survives this migration and ordinary recovery.

`:OpenCodeReload` (or `:Opencode reload`) refreshes only the current absolute
directory instance. It refuses while that directory has active work, a pending
permission, or a pending question; it does not start an inactive server or
restart the shared server. It recreates this Neovim's attached TUI after the
instance refresh. Project-scoped OpenCode configuration can therefore refresh,
but process-cached global configuration still requires `:OpenCodeStop` followed
by the next OpenCode operation.

# Credits

1) Lazyvim starter https://github.com/LazyVim/starter as nvchad's starter was inspired by Lazyvim's . It made a lot of things easier!

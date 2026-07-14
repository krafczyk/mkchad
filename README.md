**This repo is supposed to used as config by NvChad users!**

- The main nvchad repo (NvChad/NvChad) is used as a plugin by this repo.
- So you just import its modules , like `require "nvchad.options" , require "nvchad.mappings"`
- So you can delete the .git from this repo ( when you clone it locally ) or fork it :)

## OpenCode shared server

OpenCode starts lazily: ordinary MkChad startup and `:OpenCodeInfo` do not
create a server. The first OpenCode action starts one detached loopback-only
`opencode serve` backend on an automatic internal high port and a Java 21 TLS
proxy on the stable public port, then attaches a local TUI for the current
Neovim directory. `:OpenCodeInfo` reports the persisted HTTPS web URL and fresh
pinned health without changing lifecycle state.

> **Multi-user host warning:** TLS authenticates the server to clients; it does
> not authenticate clients and possession of `ca.pem` does not control access.
> Without a user-supplied `OPENCODE_SERVER_PASSWORD`, both the public TLS proxy
> and the discoverable internal loopback HTTP backend accept requests from other
> local users. Set a strong existing environment password before first use. If
> the pair is already running, set the password, run `:OpenCodeStop`, and start
> OpenCode again so both endpoints enforce it.

State lives in `${XDG_STATE_HOME:-$HOME/.local/state}/mkchad/opencode/<host>/`:
`state.json`, `server.log`, `proxy.log`, a startup lock, and `tls/`. The
directory and `tls/` are mode `0700`; state, logs, CA, PKCS12 stores, and the
random keytool password file are mode `0600`. The password value is passed to
keytool with `-storepass:file` and is never placed in argv, state, logs, or
notifications. Schema-2 state records immutable runtime executable device/inode,
launch executable device/inode, exact argv, PID start time, boot identity, and
listener information for both processes. The Java source launcher also records
the proxy source device/inode.

The proxy completes TLS first, opens one backend connection, sends only a fixed
unauthenticated `GET /global/health`, and proves the exact reverse established
tuple's socket inode belongs to the recorded backend PID before reading or
forwarding client HTTP bytes. It never reconnects a client stream. Loss of the
proxy, backend, listener, process identity, certificate identity, or pinned
health replaces both processes under the renewable lifecycle lock.

Without `OPENCODE_PORT`, the server prefers port `4096` and persists a high
fallback port when `4096` is occupied. An explicit `OPENCODE_PORT` is used
exactly or fails; it never falls back. Use `:OpenCodeStop` (or `:Opencode stop`)
to stop the **shared** server, which affects other MkChad and web clients.

Both ports bind to loopback. Set the existing `OPENCODE_SERVER_PASSWORD` (and
optional `OPENCODE_SERVER_USERNAME`) to enable OpenCode Basic Auth on both.
Credentials sent by managed clients travel only inside CA-pinned TLS on the
public endpoint; the internal HTTP endpoint receives no managed client bytes
until the proxy proves ownership of that same established connection. This
relay proof does not prevent a local user from connecting directly to the
internal port.

The stable host CA is:

`${XDG_STATE_HOME:-$HOME/.local/state}/mkchad/opencode/<host>/tls/ca.pem`

`opencode attach` receives this path through `NODE_EXTRA_CA_CERTS`, and
opencode.nvim/curl receive it through protected stdin curl configuration.
Browsers are not configured automatically: import/trust this CA manually, then
open the exact HTTPS URL shown by `:OpenCodeInfo`. Keep the CA private to the
host account even though it is a certificate; its signing key remains in the
mode-0600 `ca.p12` store. The CA and public leaf remain stable across ordinary
backend recovery and rotate only when protected certificate material is absent
or invalid.
After updating a mounted OpenCode runtime, inspect the version mismatch in
`:OpenCodeInfo`, run `:OpenCodeStop`, then use OpenCode again to launch the new
executable. Detached-child persistence depends on the SingularityCE/Apptainer
runtime; a killed proxy or backend is recovered on the next OpenCode operation. Multiple
attached TUIs using the same directory remain an OpenCode limitation.

Persisted schema-1 HTTP state is treated as legacy. Diagnostics label it and
never probe its URL with credentials. The next lifecycle operation stops only a
verified legacy process under lock before creating the schema-2 HTTPS pair;
`:OpenCodeStop` can likewise remove verified legacy state without an HTTP
probe.

Schema-2 state created before immutable executable device/inode fields were
added is malformed and is never used to signal a process. Recovery is bounded:
the next operation may create a new pair on free ports, or fail on a conflict.
Use process information from a trusted administrator to terminate any old pair
manually; do not delete pending metadata until its old processes are accounted
for.

`:OpenCodeReload` (or `:Opencode reload`) refreshes only the current absolute
directory instance. It refuses while that directory has active work, a pending
permission, or a pending question; it does not start an inactive server or
restart the shared server. It recreates this Neovim's attached TUI after the
instance refresh. Project-scoped OpenCode configuration can therefore refresh,
but process-cached global configuration still requires `:OpenCodeStop` followed
by the next OpenCode operation.

# Credits

1) Lazyvim starter https://github.com/LazyVim/starter as nvchad's starter was inspired by Lazyvim's . It made a lot of things easier!

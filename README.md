**This repo is supposed to used as config by NvChad users!**

- The main nvchad repo (NvChad/NvChad) is used as a plugin by this repo.
- So you just import its modules , like `require "nvchad.options" , require "nvchad.mappings"`
- So you can delete the .git from this repo ( when you clone it locally ) or fork it :)

## OpenCode shared server

OpenCode starts lazily: ordinary MkChad startup and `:OpenCodeInfo` do not
create a server. The first OpenCode action starts one detached, loopback-only
`opencode serve` process per user and host, then attaches a local TUI for the
current Neovim directory. `:OpenCodeInfo` reports the persisted web URL and
fresh server health without changing lifecycle state.

State lives in `${XDG_STATE_HOME:-$HOME/.local/state}/mkchad/opencode/<host>/`:
`state.json`, `server.log`, and a startup lock. The directory is mode `0700`;
state and log files are mode `0600`. State intentionally contains no password
or provider credential.

Without `OPENCODE_PORT`, the server prefers port `4096` and persists a high
fallback port when `4096` is occupied. An explicit `OPENCODE_PORT` is used
exactly or fails; it never falls back. Use `:OpenCodeStop` (or `:Opencode stop`)
to stop the **shared** server, which affects other MkChad and web clients.

The server binds to loopback, but loopback access can still be shared with
local users on multi-user hosts. Set the existing `OPENCODE_SERVER_PASSWORD`
(and optional `OPENCODE_SERVER_USERNAME`) to enable OpenCode Basic Auth.
After updating a mounted OpenCode runtime, inspect the version mismatch in
`:OpenCodeInfo`, run `:OpenCodeStop`, then use OpenCode again to launch the new
executable. Detached-child persistence depends on the SingularityCE/Apptainer
runtime; a killed server is recovered on the next OpenCode operation. Multiple
attached TUIs using the same directory remain an OpenCode limitation.

# Credits

1) Lazyvim starter https://github.com/LazyVim/starter as nvchad's starter was inspired by Lazyvim's . It made a lot of things easier!

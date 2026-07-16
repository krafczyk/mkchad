# MkChad Repository Guidance

## Purpose

This repository contains the MkChad NvChad-based Neovim configuration. In the
MkChad development workspace it is a child repository with independent Git
history.

## Parent Sprint Coordination

The parent workspace at `/data0/matthew/Projects/mkchad` owns sprint selection
and cross-repository sprint documents. Read its `AGENTS.md` before sprint work.
Do not infer a current sprint from files in this repository or from unchecked
items elsewhere.

This repository currently participates in the parent selectors
`single-opencode-server/2` and `single-opencode-server/3`. Their resolved sprint
documents are:

- `../docs/sprints/single-opencode-server/sprint_plan.md`
- `../docs/sprints/single-opencode-server/2/sprint_spec.md`
- `../docs/sprints/single-opencode-server/2/sprint_checklist.md`
- `../docs/sprints/single-opencode-server/2/threat_model.md`
- `../docs/sprints/single-opencode-server/2/audit_policy.md`
- `../docs/sprints/single-opencode-server/3/sprint_spec.md`
- `../docs/sprints/single-opencode-server/3/sprint_checklist.md`

Sprint 3 inherits the Sprint 2 threat model and audit policy. Keep the explicit
parent-resolved selector fixed for each invocation; shared repositories do not
make either sprint implicit.

If sprint work is requested from this child without an explicit parent-resolved
selector, return to the parent coordination root or ask the user to select one.
Normal repository work does not require a sprint selection.

## Live Configuration Safety

`~/.config/mkchad` is the user's live Neovim configuration. Treat it as
read-only unless the user explicitly authorizes live changes for the current
task. Perform development edits and Git operations in this repository, and use
isolated XDG paths for tests that could otherwise reach live configuration,
state, data, cache, server processes, or credentials.

## Temporary Files

Create task-specific temporary directories only beneath
`/tmp/opencode-mkchad`. Do not use an unscoped `mktemp` default or create
temporary directories directly under `/tmp` or `/var/tmp`.

## Git Workflow

Commit verified changes in this child repository before updating its gitlink in
the parent workspace. Preserve unrelated and untracked work, including
`lazy-lock.json` unless the user explicitly includes it.

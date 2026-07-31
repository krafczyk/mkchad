-- This is the MkChad owner declaration. Keep the Lazy revision here and have
-- the plugin specification consume it so status never has to guess a revision.
local M = {
  schema = 1,
  component_id = "mkchad",
  opencode_nvim_revision = "64aab776e06e37d234daba8de652366e2a288344",
  relationships = {
    {
      id = "ships-opencode-nvim",
      type = "ships",
      target_component = "opencode-nvim",
      contract = { kind = "identity", profile = "git-commit-v1" },
    },
  },
}

return M

-- This is the MkChad owner declaration. Keep the Lazy revision here and have
-- the plugin specification consume it so status never has to guess a revision.
local M = {
  schema = 1,
  component_id = "mkchad",
  opencode_nvim_revision = "37033dc157ac4c05c1e1525fe2fc9e87ae83e2ac",
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

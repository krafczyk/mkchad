local cmp = require('cmp')
local lspkind = require('lspkind')

-- Copilot enabled state
local copilot_enabled = false

-- Function to toggle Copilot for the entire session
local function toggle_copilot_session(enable)
  copilot_enabled = enable
end

-- Function to toggle Copilot for the current buffer
local function toggle_copilot_buffer(enable)
  vim.b.copilot_enabled = enable
end

cmp.setup {
  snippet = {
    expand = function(args)
      -- vim.snippet.expand(args.body) -- For native neovim snippets
      require('luasnip').lsp_expand(args.body) -- For LuaSnip users
    end,
  },
  window = {
    completion = cmp.config.window.bordered(),
    documentation = cmp.config.window.bordered(),
  },
  view = {
    entries = {name = 'custom', selection_order = 'near_cursor' },
  },
  mapping = cmp.mapping.preset.insert({
    ['<C-d>'] = cmp.mapping.scroll_docs(-4),
    ['<C-f>'] = cmp.mapping.scroll_docs(4),
    ['<C-space>'] = cmp.mapping.complete(),
    ['<CR>'] = cmp.mapping.confirm({ select = true }),
  }),
  sources = cmp.config.sources({
    { name = "nvim_lsp" },
    { name = "luasnip" },
    { name = "buffer" },
    { name = "nvim_lua" },
    { name = "async_path" },
  }),
  matching = {
    disallow_fuzzy_matching = false,
  },
  formatting = {
    format = lspkind.cmp_format({
      mode = "symbol_text",
      ellipsis_char = "...",
      menu = ({
        copilot = "[Copilot]",
        buffer = "[Buffer]",
        nvim_lsp = "[LSP]",
        luasnip = "[LuaSnip]",
        nvim_lua = "[Lua]",
        async_path = "[Path]",
        --latex_symbols = "[Latex]",
      })
    }),
  },
}

-- Command to manually request Copilot completion
-- vim.api.nvim_set_keymap(
--   'i', -- Insert mode
--   '<C-c>', -- Replace <C-c> with your preferred key combination
--   [[<Cmd>lua require('cmp').complete({ config = { sources = vim.deepcopy(require('cmp').get_config().sources, { { name = "copilot" } }) } })<CR>]],
--   { noremap = true, silent = true })



function _G.trigger_copilot_complete()
  -- Check if Copilot is enabled (globally or for the buffer)
  if not copilot_enabled and not vim.b.copilot_enabled then
    print("Copilot is not enabled for this session or buffer.")
    return
  end

  -- Modify cmp config for one completion
  cmp.abort()
  local config = require('cmp.config').get()
  local sources_copy = vim.deepcopy(config.sources)
  table.insert(sources_copy, 1, { group_index = 0, name = "copilot", option = {} })
  cmp.complete({ config = { sources = sources_copy } })
end

vim.api.nvim_set_keymap(
  'i', -- Insert mode
  '<C-c>', -- Replace <C-c> with your preferred key combination
  [[<Cmd>lua trigger_copilot_complete()<CR>]],
  { noremap = true, silent = true }
)

-- vim.api.nvim_create_user_command('CopilotComplete', function()
--   local original_sources = cmp.get_config().sources
--   local sources = vim.deepcopy(original_sources) -- Create a shallow copy of the sources
--   table.insert(sources, 1, { name = "copilot" }) -- Add Copilot as the first source

--   cmp.complete({ config = { sources = sources } }) -- Trigger completion with modified sources
-- end, {})

-- Commands to toggle Copilot
vim.api.nvim_create_user_command('EnableCopilotSession', function()
  toggle_copilot_session(true)
  print("Copilot enabled for this session.")
end, {})

vim.api.nvim_create_user_command('DisableCopilotSession', function()
  toggle_copilot_session(false)
  print("Copilot disabled for this session.")
end, {})

vim.api.nvim_create_user_command('EnableCopilotBuffer', function()
  toggle_copilot_buffer(true)
  print("Copilot enabled for this buffer.")
end, {})

vim.api.nvim_create_user_command('DisableCopilotBuffer', function()
  toggle_copilot_buffer(false)
  print("Copilot disabled for this buffer.")
end, {})

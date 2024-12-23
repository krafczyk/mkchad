local cmp = require('cmp')
local lspkind = require('lspkind')
cmp.setup {
  snippet = {
    expand = function(args)
      vim.snippet.expand(args.body) -- For native neovim snippets
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
    --{ name = "copilot" },
    { name = "nvim_lsp" },
    --{ name = "luasnip" },
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
        buffer = "[Buffer]",
        nvim_lsp = "[LSP]",
        --luasnip = "[LuaSnip]",
        nvim_lua = "[Lua]",
        async_path = "[Path]",
        --latex_symbols = "[Latex]",
      })
    }),
  },
}

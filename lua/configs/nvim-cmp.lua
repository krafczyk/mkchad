local cmp = require('cmp')
local lspkind = require('lspkind')
cmp.setup {
  view = {
    entries = {name = 'custom', selection_order = 'near_cursor' },
  },
  formatting = {
    format = lspkind.cmp_format({
      mode = "symbol_text",
      menu = ({
        buffer = "[Buffer]",
        nvim_lsp = "[LSP]",
        --luasnip = "[LuaSnip]",
        nvim_lua = "[Lua]",
        --latex_symbols = "[Latex]",
      })
    }),
  },
}

-- core defaults applied to *every* LSP
vim.lsp.config('*', {
  capabilities = require('cmp_nvim_lsp').default_capabilities(),
})

require("mason-lspconfig").setup({
    ensure_installed = { "jdtls", "ts_ls", "bashls", "basedpyright"},
    automatic_enable = true,
})

dofile(vim.g.base46_cache .. "lsp")
require("nvchad.lsp").diagnostic_config()

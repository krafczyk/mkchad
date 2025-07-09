vim.notify("test")

local map = vim.keymap.set
local default_M = {}

-- Define attach methods
-- export on_attach & capabilities
default_M.on_attach = function(_, bufnr)
    local function opts(desc)
        return { buffer = bufnr, desc = "LSP " .. desc }
    end

    map("n", "K", vim.lsp.buf.hover, opts "Hover")
    map("n", "gD", vim.lsp.buf.declaration, opts "Go to declaration")
    map("n", "gd", vim.lsp.buf.definition, opts "Go to definition")
    map("n", "gi", vim.lsp.buf.implementation, opts "Go to implementation")
    map("n", "go", vim.lsp.buf.type_definition, opts "Go to type definition")
    map("n", "gr", vim.lsp.buf.references, opts "Show references")
    map("n", "gs", vim.lsp.buf.signature_help, opts "Show signature help")
    -- map('n', '<leader>d', vim.lsp.diagnostic.get_line_diagnostics, opts "Get line diagnostics") -- Not working I think..
    --map("n", "<leader>wa", vim.lsp.buf.add_workspace_folder, opts "Add workspace folder")
    --map("n", "<leader>wr", vim.lsp.buf.remove_workspace_folder, opts "Remove workspace folder")

    --map("n", "<leader>wl", function()
    --    print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
    --end, opts "List workspace folders")

    --map("n", "<leader>ra", require "nvchad.lsp.renamer", opts "NvRenamer")

    --map({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, opts "Code action")
end

-- capabilities from https://github.com/VonHeikemen/lsp-zero.nvim?tab=readme-ov-file#quickstart-for-the-impatient
-- vim.api.nvim_create_autocmd('LspAttach', {
--   desc = 'LSP actions',
--   callback = function(event)
--     local opts = {buffer = event.buf}

--     vim.keymap.set('n', 'K', '<cmd>lua vim.lsp.buf.hover()<cr>', opts)
--     vim.keymap.set('n', 'gd', '<cmd>lua vim.lsp.buf.definition()<cr>', opts)
--     vim.keymap.set('n', 'gD', '<cmd>lua vim.lsp.buf.declaration()<cr>', opts)
--     vim.keymap.set('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<cr>', opts)
--     vim.keymap.set('n', 'go', '<cmd>lua vim.lsp.buf.type_definition()<cr>', opts)
--     vim.keymap.set('n', 'gr', '<cmd>lua vim.lsp.buf.references()<cr>', opts)
--     vim.keymap.set('n', 'gs', '<cmd>lua vim.lsp.buf.signature_help()<cr>', opts)
--     vim.keymap.set('n', '<F2>', '<cmd>lua vim.lsp.buf.rename()<cr>', opts)
--     vim.keymap.set({'n', 'x'}, '<F3>', '<cmd>lua vim.lsp.buf.format({async = true})<cr>', opts)
--     vim.keymap.set('n', '<F4>', '<cmd>lua vim.lsp.buf.code_action()<cr>', opts)
--   end,
-- })

capabilities = vim.lsp.protocol.make_client_capabilities()

capabilities.textDocument.completion.completionItem = {
    documentationFormat = { "markdown", "plaintext" },
    snippetSupport = true,
    preselectSupport = true,
    insertReplaceSupport = true,
    labelDetailsSupport = true,
    deprecatedSupport = true,
    commitCharactersSupport = true,
    tagSupport = { valueSet = { 1 } },
    resolveSupport = {
        properties = {
            "documentation",
            "detail",
            "additionalTextEdits",
        },
    },
}

-- core defaults applied to *every* LSP
--vim.lsp.config('*', {
--  capabilities = capabilities,
--})

require("mason-lspconfig").setup({
    ensure_installed = { "jdtls", "ts_ls", "bashls", "basedpyright"},
    automatic_enable = true,
})

dofile(vim.g.base46_cache .. "lsp")
require("nvchad.lsp").diagnostic_config()

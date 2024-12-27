-- require("lspconfig").setup({})
require("mason-lspconfig").setup({
    automatic_installation = true,
    ensure_installed = { "lua_ls", "pyright", "clangd" }
})

local map = vim.keymap.set
local default_M = {}

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

default_M.on_init = function(client, _)
    if client.supports_method "textDocument/semanticTokens" then
        client.server_capabilities.semanticTokensProvider = nil
    end
end

default_M.capabilities = vim.lsp.protocol.make_client_capabilities()

default_M.capabilities.textDocument.completion.completionItem = {
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

require("mason-lspconfig").setup_handlers {
    -- The first entry (without a key) will be the default handler
    -- and will be called for each installed server that doesn't have
    -- a dedicated handler.
    function (server_name) -- default handler (optional)
        require("lspconfig")[server_name].setup {
          on_attach = default_M.on_attach,
          capabilities = default_M.capabilities,
          on_init = default_M.on_init,
        }
    end,
    -- Next, you can provide a dedicated handler for specific servers.
    -- For example, a handler override for the `rust_analyzer`:
    [ "lua_ls" ] = function ()
        dofile(vim.g.base46_cache .. "lsp")
        require("nvchad.lsp").diagnostic_config()

        require("lspconfig").lua_ls.setup {
            cmd = {
                "lua-language-server",
                "--logpath=~/.cache/lua-language-server/log",
                "--metapath=~/.cache/lua-language-server/meta"},
            filetypes = { "lua" },
            on_attach = default_M.on_attach,
            capabilities = default_M.capabilities,
            on_init = default_M.on_init,

            settings = {
                Lua = {
                    diagnostics = {
                        globals = { "vim" },
                    },
                    workspace = {
                        library = {
                            vim.fn.expand "$VIMRUNTIME/lua",
                            vim.fn.expand "$VIMRUNTIME/lua/vim/lsp",
                            vim.fn.stdpath "data" .. "/lazy/ui/nvchad_types",
                            vim.fn.stdpath "data" .. "/lazy/lazy.nvim/lua/lazy",
                            "${3rd}/luv/library",
                        },
                        maxPreload = 100000,
                        preloadFileSize = 10000,
                    },
                },
            },
        }
    end,
    ["java_language_server"] = function()
        require("lspconfig").java_language_server.setup {
            on_attach = default_M.on_attach,
            capabilities = default_M.capabilities,
            on_init = default_M.on_init,
            handlers = {
                -- Fixes https://github.com/georgewfraser/java-language-server/issues/267
                ['client/registerCapability'] = function(err, result, ctx, config)
                    local registration = {
                        registrations = { result },
                    }
                    return vim.lsp.handlers['client/registerCapability'](err, registration, ctx, config)
                end
            },
        }
    end,
    --     local lspconfig = require("lspconfig")
    --     local lua_ls_config = lspconfig.lua_ls

    --     if lua_ls_config then
    --         -- Check that the existing cmd property is correct
    --         local correct_cmd = {
    --             "lua-language-server",
    --             "--logpath=~/.cache/lua-language-server/log",
    --             "--metapath=~/.cache/lua-language-server/meta"}
    --         -- Modify the `cmd property of the existing configuration
    --         if lua_ls_config.cmd ~= correct_cmd then
    --             lua_ls_config.cmd = correct_cmd

    --             -- Restart the language server to apply changes
    --             vim.lsp.stop_client(vim.lsp.get_active_clients({ name = "lua_ls"}))
    --             lua_ls_config.manager.try_add_wrapper()
    --         end
    --     else
    --         vim.notify("lua_ls configuration not found!", vim.log.levels.ERROR)
    --     end

    -- ["rust_analyzer"] = function ()
    --     require("rust-tools").setup {}
    -- end
}

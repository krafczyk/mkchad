-- require('plugins.configs.lspconfig')

---- load defaults i.e lua_lsp
--require("nvchad.configs.lspconfig").defaults()

--local lspconfig = require "lspconfig"

---- Special lua_ls configuration
--local lua_ls_config = lspconfig.lua_ls

--if lua_ls_config then
--    -- Check that the existing cmd property is correct
--    local correct_cmd = {
--        '/nvim/lua-language-server/bin/lua-language-server',
--        '--logpath',
--        '~/.cache/lua-language-server/log',
--        '--metapath',
--        '~/.cache/lua-language-server/meta'}
--    --local correct_cmd = { "/nvim/lua-language-server/bin/lua-language-server --logpath=~/.cache/lua-language-server/log --metapath=~/.cache/lua-language-server/meta"}
--    -- Modify the `cmd property of the existing configuration
--    vim.notify(vim.inspect(correct_cmd), vim.log.levels.INFO)
--    vim.notify(vim.inspect(lua_ls_config.cmd), vim.log.levels.INFO)
--    if lua_ls_config.cmd ~= correct_cmd then
--        lua_ls_config.cmd = correct_cmd
--        vim.notify(vim.inspect(lua_ls_config.cmd), vim.log.levels.INFO)
--        -- Restart the language server to apply changes
--        --vim.lsp.stop_client(vim.lsp.get_active_clients({ name = "lua_ls"}))
--        --lua_ls_config.manager.try_add_wrapper()
--    end
--else
--    vim.notify("lua_ls configuration not found!", vim.log.levels.ERROR)
--end
--vim.notify(vim.inspect(require("lspconfig").lua_ls.cmd))


-- -- EXAMPLE
-- local servers = { "html", "cssls", "bashls" }
-- local nvlsp = require "nvchad.configs.lspconfig"

-- -- lsps with default config
-- for _, lsp in ipairs(servers) do
--   lspconfig[lsp].setup {
--     on_attach = nvlsp.on_attach,
--     on_init = nvlsp.on_init,
--     capabilities = nvlsp.capabilities,
--   }
-- end

-- configuring single server, example: typescript
-- lspconfig.ts_ls.setup {
--   on_attach = nvlsp.on_attach,
--   on_init = nvlsp.on_init,
--   capabilities = nvlsp.capabilities,
-- }

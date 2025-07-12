local function bufmap(buf)
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "LSP " .. desc })
  end

  map("n", "K", vim.lsp.buf.hover, "Hover")
  map("n", "gD", vim.lsp.buf.declaration, "Go to declaration")
  map("n", "gd", vim.lsp.buf.definition, "Go to definition")
  map("n", "gi", vim.lsp.buf.implementation, "Go to implementation")
  map("n", "go", vim.lsp.buf.type_definition, "Go to type definition")
  map("n", "gr", vim.lsp.buf.references, "Show references")
  map("n", "gs", vim.lsp.buf.signature_help, "Show signature help")
end

-- fire once for every client-buffer pair
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(ev) bufmap(ev.buf) end,
})

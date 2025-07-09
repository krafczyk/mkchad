return {
  handlers = {
    ['client/registerCapability'] = function(err, result, ctx, config)
      local registration = { registrations = { result }, }
      return vim.lsp.handlers['client/registerCapability'](err, registration, ctx, config)
    end
  }
}

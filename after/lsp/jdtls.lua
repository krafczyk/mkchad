local util = require("lspconfig.util")   -- gives us add_hook_before

return {
  -- run your hook, but keep the one defined by lspconfig
  on_init = util.add_hook_before(function(client)
    if client.config.settings then
      client.notify(
        "workspace/didChangeConfiguration",
        { settings = client.config.settings }
      )
    end
  end),
}

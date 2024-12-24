require('codecompanion').setup({
  strategies = {
    chat = {
      adapter = "openai",
      keymaps = {
        send = {
          modes = {
            n = { "<C-s>" },
          }
        }
      }
    },
    inline = {
      -- adapter = "copilot",
      adapter = "openai",
    },
  },
  adapters = {
    openai = function()
      vim.notify("openai function was run.")
      return require("codecompanion.adapters").extend("openai", {
        env = {
          api_key = "cmd:tr -d '\n' < ~/.config/openai.token",
        }
      })
    end
  },
  opts = {
    language = "English"
  },
})

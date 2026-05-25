return {
  {
    "stevearc/conform.nvim",
    -- event = 'BufWritePre', -- uncomment for format on save
    opts = require "configs.conform",
  },
  -- Basic plugins which don't need anything special
  {
    "tpope/vim-commentary",
    lazy=false,
  },
  -- {
  --   "jedrzejboczar/possession.nvim",
  --   lazy=false,
  --   dependencies = {
  --     "nvim-telescope/telescope.nvim"
  --   },
  --   config = function()
  --     require "configs.possession"
  --   end
  -- },
  {
    "folke/noice.nvim",
    event = "VeryLazy",
    --opts = {},
    dependencies = {
      -- if you lazy-load any plugin below, make sure to add proper `module="..."` entries
      "MunifTanjim/nui.nvim",
      -- OPTIONAL:
      --   `nvim-notify` is only needed, if you want to use the notification view.
      --   If not available, we use `mini` as the fallback
      "rcarriga/nvim-notify"
    },
    config = function()
      require "configs.noice"
    end
  },
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      input = { enabled = true },
      terminal = { enabled = true },
      picker = {
        enabled = true,
        actions = {
          opencode_send = function(...)
            return require("opencode").snacks_picker_send(...)
          end,
        },
        win = {
          input = {
            keys = {
              ["<a-a>"] = { "opencode_send", mode = { "n", "i" } },
            },
          },
        },
      },
    },
  },
  -- These are some examples, uncomment them if you want to see them work!
  {
    "zbirenbaum/copilot.lua",
    config = function()
      require "configs.copilot"
    end,
  },
  {
    "zbirenbaum/copilot-cmp",
    dependencies = {
      "zbirenbaum/copilot.lua",
    },
    config = function()
      require "configs.copilot-cmp"
    end,
  },
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "zbirenbaum/copilot-cmp",
      "hrsh7th/cmp-nvim-lsp",
      "onsails/lspkind.nvim",
      "https://codeberg.org/FelipeLema/cmp-async-path.git"
    },
    config = function()
      require "configs.nvim-cmp"
    end
  },
  {
    "mason-org/mason-lspconfig.nvim",
    event = {"BufReadPre", "BufNewFile"},
    opts = {},
    dependencies = {
      { "mason-org/mason.nvim", opts = {} },
      "neovim/nvim-lspconfig",
      "ray-x/lsp_signature.nvim"
    },
    config = function()
      require("mason").setup()
      require "configs.lsp"
    end
  },
  {
    "ray-x/lsp_signature.nvim",
    opts = {
      bind = true,
      handler_opts = {
        border = "rounded"
      }
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",
    lazy = false,

    opts = {
      install_dir = vim.fn.stdpath("data") .. "/site",
      ensure_install = {
        "vim",
        "lua",
        "vimdoc",
        "html",
        "css",
        "c",
        "python",
        "bash",
        "markdown",
      },
    },

    config = require("configs.nvim-treesitter"),
  },
  -- {
  --   "olimorris/codecompanion.nvim",
  --   dependencies = {
  --     "nvim-lua/plenary.nvim",
  --     "nvim-treesitter/nvim-treesitter",
  --     "echasnovski/mini.nvim",
  --   },
  --   config = function()
  --     require "configs.codecompanion"
  --   end,
  -- },

  {
    "nickjvandyke/opencode.nvim",
    version = "*",
    cmd = "Opencode",
    keys = {
      {
        "<leader>oa",
        function()
          require("opencode").ask("@this: ", { submit = true })
        end,
        mode = { "n", "x" },
        desc = "Ask opencode",
      },
      {
        "<leader>os",
        function()
          require("opencode").select()
        end,
        mode = { "n", "x" },
        desc = "Select opencode",
      },
      {
        "<leader>ot",
        function()
          require("opencode").toggle()
        end,
        mode = { "n", "t" },
        desc = "Toggle opencode",
      },
      {
        "<leader>oo",
        function()
          return require("opencode").operator("@this ")
        end,
        mode = { "n", "x" },
        desc = "Add range to opencode",
        expr = true,
      },
      {
        "<leader>ol",
        function()
          return require("opencode").operator("@this ") .. "_"
        end,
        desc = "Add line to opencode",
        expr = true,
      },
      {
        "<leader>ou",
        function()
          require("opencode").command("session.half.page.up")
        end,
        desc = "Scroll opencode up",
      },
      {
        "<leader>od",
        function()
          require("opencode").command("session.half.page.down")
        end,
        desc = "Scroll opencode down",
      },
    },
    dependencies = {
      "folke/snacks.nvim",
    },
    config = function()
      require "configs.opencode"
    end,
  },
}

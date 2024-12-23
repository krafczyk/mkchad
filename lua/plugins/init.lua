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
  -- These are some examples, uncomment them if you want to see them work!
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      --"zbirenbaum/copilot.lua",
      "hrsh7th/cmp-nvim-lsp",
      "onsails/lspkind.nvim",
      "https://codeberg.org/FelipeLema/cmp-async-path.git"
    },
    opts = {
      sources = {
        --{ name = "copilot" },
        { name = "nvim_lsp" },
        --{ name = "luasnip" },
        { name = "buffer" },
        --{ name = "nvim_lua" },
        { name = "async_path" },
      }
    },
    --config = function()
    --  require "configs.nvim-cmp"
    --end
  },
  {
    "williamboman/mason-lspconfig.nvim",
    lazy=false,
    dependencies={
      "neovim/nvim-lspconfig",
      "williamboman/mason.nvim"
    },
    config = function()
      require "configs.mason-lspconfig"
    end
  },
  {
  	"nvim-treesitter/nvim-treesitter",
    config = function()
      require "configs.nvim-treesitter"
    end,
  	opts = {
  		ensure_installed = {
  			"vim", "lua", "vimdoc",
        "html", "css", "c", "python",
        "bash", "markdown"
  		},
  	},
  },
  -- {
  --   "olimorris/codecompanion.nvim",
  --   dependencies = {
  --     "nvim-lua/plenary.nvim",
  --     "nvim-treesitter/nvim-treesitter",
  --   },
  --   config = function()
  --     require("codecompanion").setup()
  --   end,
  -- },
}

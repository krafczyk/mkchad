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
  {
    "olimorris/codecompanion.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    config = function()
      require "configs.codecompanion"
    end,
  },
}

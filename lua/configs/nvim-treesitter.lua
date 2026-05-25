return function(_, opts)
  require("nvim-treesitter").setup(opts)

  vim.api.nvim_create_autocmd("FileType", {
    callback = function(args)
      pcall(vim.treesitter.start, args.buf)
      vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end,
  })
end

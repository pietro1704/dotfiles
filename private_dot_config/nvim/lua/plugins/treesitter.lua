-- Override treesitter: skip parsers that fail to download behind corporate network
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ignore_install = opts.ignore_install or {}
      vim.list_extend(opts.ignore_install, { "jsonc" })

      -- Remove jsonc from ensure_installed so it won't try to update
      if opts.ensure_installed then
        opts.ensure_installed = vim.tbl_filter(function(lang)
          return lang ~= "jsonc"
        end, opts.ensure_installed)
      end
    end,
  },
}

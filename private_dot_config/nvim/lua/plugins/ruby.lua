-- Ruby / Rails
return {
  -- Treesitter: adiciona Ruby e ERB
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, { "ruby", "erb" })
    end,
  },

  -- ruby-lsp via mise (não via Mason — sistema tem ruby 2.6, muito antigo)
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ruby_lsp = {
          mason = false,
          cmd = {
            -- path dinâmico: funciona após upgrades do ruby sem editar config
            vim.fn.trim(vim.fn.system("/usr/local/bin/mise which ruby-lsp 2>/dev/null")),
          },
        },
      },
    },
  },

  -- Syntax e highlights extras para Ruby
  { "vim-ruby/vim-ruby", ft = { "ruby", "eruby" } },

  -- Rails: gf em routes/controllers, :Emodel, :Econtroller, etc.
  { "tpope/vim-rails", ft = { "ruby", "eruby" } },

  -- Comandos Rails via Telescope (ROR)
  {
    "weizheheng/ror.nvim",
    ft = { "ruby", "eruby" },
    dependencies = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
    opts = {},
  },
}

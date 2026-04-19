-- Overrides e extras do editor
return {
  -- Neo-tree: mostrar arquivos ocultos por padrão, sem filtros
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = {
      filesystem = {
        filtered_items = {
          visible = true,       -- mostra arquivos filtrados (em cinza)
          hide_dotfiles = false,
          hide_gitignored = false,
        },
        follow_current_file = { enabled = true },
      },
    },
  },

  -- Telescope: layout consistente com o setup anterior
  {
    "nvim-telescope/telescope.nvim",
    opts = {
      defaults = {
        layout_strategy = "horizontal",
        layout_config = { prompt_position = "top" },
        sorting_strategy = "ascending",
        winblend = 0,
      },
    },
  },

  -- lazydev: intellisense para desenvolvimento de configs Lua/Neovim
  {
    "folke/lazydev.nvim",
    ft = "lua",
    opts = {},
  },
}

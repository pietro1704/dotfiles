-- Catppuccin Mocha — consistente com Alacritty e tmux
return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    opts = {
      flavour = "mocha",
      integrations = {
        cmp = true,
        gitsigns = true,
        neotree = true,
        telescope = { enabled = true },
        treesitter = true,
        which_key = true,
        mason = true,
        lsp_trouble = true,
        indent_blankline = { enabled = true },
      },
    },
  },
  {
    "LazyVim/LazyVim",
    opts = { colorscheme = "catppuccin-mocha" },
  },
}

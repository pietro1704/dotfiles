-- Autocmds carregados no evento VeryLazy

-- Spell check apenas em arquivos de texto/prosa
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "text", "gitcommit", "mail", "tex" },
  callback = function()
    vim.opt_local.spell = true
    vim.opt_local.spelllang = "en_us,pt_br"
  end,
})

-- Ruby: indentação de 2 espaços + comentário correto
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "ruby", "eruby" },
  callback = function()
    vim.opt_local.shiftwidth = 2
    vim.opt_local.tabstop = 2
    vim.opt_local.softtabstop = 2
    vim.opt_local.expandtab = true
    vim.opt_local.commentstring = "# %s"
  end,
})

-- Highlight ao yankar
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function()
    vim.highlight.on_yank()
  end,
})

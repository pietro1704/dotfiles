-- Keymaps carregados no evento VeryLazy
-- LazyVim já define a maioria; aqui ficam os atalhos extras

local map = vim.keymap.set

-- Clipboard do sistema
map({ "n", "v" }, "<leader>y", '"+y', { desc = "Yank → clipboard do sistema" })
map({ "n", "v" }, "<leader>Y", '"*y', { desc = "Yank → selection clipboard" })
map({ "n", "v" }, "<leader>p", '"+p', { desc = "Paste ← clipboard do sistema" })

-- Ctrl+X → Telescope find_files
map("n", "<C-x>", function()
  require("telescope.builtin").find_files()
end, { desc = "Find Files (Telescope)" })

-- Ctrl+O → toggle file explorer (neo-tree)
map("n", "<C-o>", "<cmd>Neotree toggle<cr>", { desc = "Toggle file explorer" })

-- Toggle comentário com backslash
map("n", "\\", function()
  require("Comment.api").toggle.linewise.current()
end, { desc = "Toggle comment" })
map("v", "\\", function()
  require("Comment.api").toggle.linewise(vim.fn.visualmode())
end, { desc = "Toggle comment (visual)" })

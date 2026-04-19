-- Options carregadas antes do lazy.nvim
-- LazyVim já define boas defaults; aqui ficam apenas os overrides

local opt = vim.opt

opt.relativenumber = true     -- números relativos (melhor para motions)
opt.colorcolumn = "100"       -- coluna visual a 100 chars
opt.scrolloff = 8             -- mínimo 8 linhas acima/abaixo do cursor
opt.cmdheight = 1             -- barra de comando com 1 linha
opt.updatetime = 100          -- tempo para gravar swap e disparar CursorHold
opt.spell = false             -- spell global off (ativado por FileType em autocmds.lua)

-- Tabs: 2 espaços (padrão para Ruby, Lua, JS)
opt.tabstop = 2
opt.shiftwidth = 2
opt.softtabstop = 2
opt.expandtab = true

-- Splits abrem para baixo e para a direita
opt.splitbelow = true
opt.splitright = true

-- Busca recursiva + wildmenu
opt.path:append("**")
opt.wildignore:append({ "**/node_modules/**", "*.exe", "*.dll", "*.pdb" })

-- Usa git grep como grepprg (respeita .gitignore)
opt.grepprg = "git\\ grep\\ -n"

set cursorline
set number

syntax on
filetype plugin indent on
filetype on
filetype indent on
set spell

source ~/.vimrc
source ~/.config/nvim/vim-plug/plugins.vim

autocmd FileType ruby setlocal expandtab shiftwidth=2 tabstop=2
autocmd FileType eruby setlocal expandtab shiftwidth=2 tabstop=2

" remap envoke key
nnoremap <silent> <C-x> :FZF<CR>

noremap \ :Commentary<CR>
autocmd FileType ruby setlocal commentstring=#\ %s

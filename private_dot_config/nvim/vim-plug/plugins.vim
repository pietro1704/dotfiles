" auto-install vim-plug
if empty(glob('~/.config/nvim/autoload/plug.vim'))
  silent !curl -fLo ~/.config/nvim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  "autocmd VimEnter * PlugInstall
  "autocmd VimEnter * PlugInstall | source $MYVIMRC
endif

call plug#begin('~/.config/nvim/autoload/plugged')

Plug 'dense-analysis/ale'
Plug 'weizheheng/ror.nvim'
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim', { 'branch': '0.1.x' }
Plug 'rcarriga/nvim-notify'
Plug 'stevearc/dressing.nvim'

Plug 'vim-ruby/vim-ruby'
Plug 'tpope/vim-rails'
Plug '/usr/local/opt/fzf'
Plug 'junegunn/fzf.vim'
Plug 'Shougo/neocomplete.vim' "  neocomplete Plugin
Plug 'tpope/vim-commentary'
Plug 'lambdalisue/vim-gitignore'

call plug#end()

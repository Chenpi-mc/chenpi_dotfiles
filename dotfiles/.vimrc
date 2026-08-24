"显示行号
set number
"显示相对行号
set relativenumber
"高亮当前行
set cursorline
"语法高亮
syntax on 

" 开启自动缩进，新的一行会自动与上一行对齐
set autoindent
" 在输入搜索词时，实时高亮显示匹配项（增量搜索）
set incsearch

" 高亮显示所有搜索结果
set hlsearch

" 搜索时忽略大小写
set ignorecase

" 如果搜索词中包含了大写字母，则自动切换为大小写敏感搜索
set smartcase
" 开启持久化撤销（undo），即使关闭再打开文件，也能撤销之前的更改
set undofile

" undo目录
silent !mkdir -p ~/.cache/vim/undo
set undodir=~/.cache/vim/undo

" === y 正常复制到Vim内部，<leader>y 复制到系统剪贴板 ===
let mapleader = " "
nnoremap <leader>y "+y
vnoremap <leader>y "+y
nnoremap <leader>Y "+Y

" === <leader>x 剪切到系统剪贴板 ===
nnoremap <leader>x "+x
vnoremap <leader>x "+x

" === <leader>p 从系统剪贴板粘贴 ===
nnoremap <leader>p "+p
vnoremap <leader>p "+p
nnoremap <leader>P "+P
vnoremap <leader>P "+P

" 接管鼠标事件
set mouse=a

" === fcitx5 状态切换与恢复 ===
let g:fcitx_state = 1
autocmd InsertLeave * let g:fcitx_state = system("fcitx5-remote")[0] | call job_start("fcitx5-remote -c")
autocmd InsertEnter * if g:fcitx_state == '2' | call job_start("fcitx5-remote -o") | endif
autocmd VimEnter * call job_start("fcitx5-remote -c")

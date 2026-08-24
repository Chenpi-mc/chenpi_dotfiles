-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")

-- fcitx5 状态切换与恢复
local fcitx_st = ""
vim.api.nvim_create_autocmd("InsertLeave", { callback = function() fcitx_st = vim.fn.system("fcitx5-remote"); vim.fn.jobstart("fcitx5-remote -c") end })
vim.api.nvim_create_autocmd("InsertEnter", { callback = function() if fcitx_st:match("2") then vim.fn.jobstart("fcitx5-remote -o") end end })
vim.api.nvim_create_autocmd("VimEnter", { callback = function() vim.fn.jobstart("fcitx5-remote -c") end })


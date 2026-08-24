# fastfetch 配置

一个带图片 logo 的 fastfetch 配置，模块以树形结构展示。

## 安装

```bash
# 备份已有的配置（如果有）
mv ~/.config/fastfetch ~/.config/fastfetch.bak

# 解压到配置目录
mkdir -p ~/.config
tar -xzf fastfetch-config.zip -C ~/.config

# 快捷重命名为 fastfetch（如果 zip 里的目录名不同）
```

> zip 解压后目录结构应为 `~/.config/fastfetch/{config.jsonc, images/, README.md}`，
> 如不符合请手动把 `config.jsonc` 和 `images/` 移动到 `~/.config/fastfetch/`。

## 要求

- 终端必须支持 **kitty 图像协议**（kitty、foot、wezterm、Ghostty 等），
  否则 logo 无法显示。不支持的终端可把 `config.jsonc` 里
  `"logo"` 的 `"type": "kitty-direct"` 改为 `"source": "ascii.txt"` 使用备用 ASCII 图。
- 已安装 [Nerd Fonts](https://www.nerdfonts.com/)（图标和特殊字符需要）。

## 预览

```text
 ╭─ user@host
 ├─ OS
 ├─ Kernel
 ├─ WM
 ╰─ Shell
 ╭─ CPU
 ├─ GPU
 ╰─ Memory
 ● ● ● ● ● ●
```

## 自定义

- logo 图片：替换 `images/` 里的 PNG
- 颜色：各模块的 `keyColor` 字段
- 更多模块参考：<https://github.com/fastfetch-cli/fastfetch/wiki/JSON-Configuration>

# Markdown 语法速查

> 参考：菜鸟教程、CommonMark 规范、GitHub 官方写作指南

Markdown 是一种轻量级标记语言，用纯文本就能写出结构化文档。`.md` 文件在任何地方都能打开，GitHub 仓库的 README 就是用 Markdown 写的。

---

## 1. 标题

`#` 的数量代表标题层级，1 到 6 级：

```markdown
# 一级标题
## 二级标题
### 三级标题
```

## 2. 段落与换行

```markdown
这是第一段。

空一行才是新段落。
```

段内换行要在行尾加两个空格：

```markdown
这是第一行··
这是第二行
```

## 3. 强调

```markdown
*斜体* 或 _斜体_
**粗体** 或 __粗体__
***粗斜体***
~~删除线~~
```

效果：*斜体*、**粗体**、***粗斜体***、~~删除线~~

## 4. 列表

无序列表（`-` `*` `+` 都行）：

```markdown
- 苹果
- 香蕉
  - 子项（缩进两个空格）
```

有序列表：

```markdown
1. 第一
2. 第二
3. 第三
```

## 5. 链接与图片

```markdown
[链接文字](https://github.com)

![图片说明](https://图片地址.png)
```

GitHub 上相对路径也能用，比如 `[教程](../Git上传配置到GitHub新手教程.md)`。

## 6. 代码

行内代码用反引号：

```markdown
运行 `sudo pacman -S git` 安装 git。
```

代码块用三个反引号，可以指定语言高亮：

````markdown
```bash
git add .
git commit -m "first commit"
git push
```
````

## 7. 引用

```markdown
> 这是一段引用。
> 可以多行。
>>
>> 还能嵌套。
```

## 8. 表格

```markdown
| 单词 | 意思 |
|------|------|
| git  | 版本管理工具 |
| push | 推送 |
```

## 9. 分割线

```markdown
---
```

## 10. 任务列表（GitHub 支持）

```markdown
- [x] 已完成的事
- [ ] 待办的事
```

## 11. 转义

想显示 `#`、`*` 这类特殊符号本身，前面加反斜杠：

```markdown
\# 这不是标题
\* 不是列表
```

---

## 常用技巧

- **目录（TOC）**：GitHub 会自动在 README 长文档顶部生成跳转目录
- **徽章（Badge）**：用 shields.io 可以加"构建状态""协议"等小图标，让 README 更专业
- **Emoji**：直接输入 `:smile:` 或粘贴 Emoji 字符都能显示
- **HTML**：Markdown 里可以混写 HTML，比如 `<details>` 折叠块、`<img>` 调图片宽度

## 练习建议

你的 `README.md` 就是最好的练习场。改一改、推一推，GitHub 上马上能看到渲染效果，改坏了也能 `git revert` 回来，放心折腾。

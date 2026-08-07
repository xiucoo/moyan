# 墨言（Moyan）

参考妙言体验的 macOS Markdown 笔记应用。

## 功能

- 三栏布局：文件夹 / 笔记列表 / 编辑器
- Markdown 语法高亮、工具栏格式化、实时预览（编辑 / 预览 / 分栏）
- 主题：跟随系统 / 浅色 / 深色，可切换强调色
- 导出当前笔记或整个文件夹为 PDF（`⌘E` / `⌘⇧E`）
- 存储：本机 `~/Documents/墨言`，或迁移到 **iCloud Drive/墨言** 多设备同步
- 搜索、新建笔记（`⌘N`）、新建文件夹（`⌘⇧N`）

## 运行

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
open Moyan.xcodeproj
```

在 Xcode 中选择 **My Mac**，按 `⌘R` 运行。

## iCloud 同步说明

1. 系统设置中登录 Apple ID，并开启 **iCloud 云盘**
2. 打开墨言 → **设置** → 将「笔记库位置」切换为 **iCloud Drive**
3. 选择「迁移并切换」后，笔记会出现在 Finder 的 `iCloud Drive/墨言`
4. 其它 Mac 安装墨言并选择同一位置即可同步（应用会定期刷新外部更改）

## 要求

- macOS 14+
- Xcode 16+

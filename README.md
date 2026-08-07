# 墨言（Moyan）

面向 macOS 的轻量 Markdown 笔记应用。三栏布局，笔记以本机文件夹中的 `.md` 文件存储，可选 iCloud Drive 多设备同步。

## 功能

### 编辑与预览
- 三栏：文件夹 / 笔记列表 / 编辑器
- Markdown 语法高亮与工具栏格式化
- 编辑 / 预览 / 分栏三种视图
- 正文查找与替换（`⌘F` / `⌘⌥F`）
- 文字颜色与背景色
- 导出当前笔记或整个文件夹为 PDF（`⌘E` / `⌘⇧E`）

### 组织与浏览
- 文件夹管理：新建、重命名、从磁盘刷新、在 Finder 中打开
- 笔记列表 / 画廊两种浏览方式
- 标签：侧栏筛选，笔记内增删
- 全文搜索：标题、副标题、标签与正文
- 子任务：从正文选区新建关联子笔记
- 工作日志：按今天 / 昨天 / 月份分区；日期标题与 `> 简介` 副标题

### 附件与办公
- 链接并预览 WPS 表格 / 文档（`.xlsx` / `.docx`）
- 表格可内嵌网格预览，也可用 WPS 打开编辑
- 文档走 Quick Look，编辑交给外部应用

### 外观
- 跟随系统 / 浅色 / 深色
- 强调色：叶绿、青石、雾蓝、藤紫、琥珀

### Cursor AI（可选）
- 选区提问，答复可插入笔记
- 对文件夹或笔记做 AI 分析
- 需在设置中配置 Cursor API Key（默认模型 grok-4.5）

## 要求

- macOS 14+
- Xcode 16+
- （可选）已安装 WPS，用于编辑链接的办公文件
- （可选）Cursor API Key，用于 AI 功能

## 运行

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
open Moyan.xcodeproj
```

在 Xcode 中选择 **My Mac**，按 `⌘R` 运行。

也可先 `⌘B` 编译，再双击 `运行墨言.command` 启动已编译的 Debug 包。

## 笔记库位置

| 模式 | 路径 |
|------|------|
| 本机 Documents（默认） | `~/Documents/墨言` |
| iCloud Drive | `iCloud Drive/墨言` |

### 切换到 iCloud

1. 系统设置中登录 Apple ID，并开启 **iCloud 云盘**
2. 墨言 → **设置** → 将「笔记库位置」切换为 **iCloud Drive**
3. 选择「迁移并切换」后，笔记会出现在 Finder 的 `iCloud Drive/墨言`
4. 其它 Mac 安装墨言并选择同一位置即可同步

应用会定期扫描磁盘变化；也可在设置中「按磁盘重建索引」，以文件夹与 `.md` 文件为准重建列表。

### 从妙言迁移

将笔记复制到「文稿/墨言」（勿复制到其它同名目录），然后在设置中点击「按磁盘重建索引」。根目录下的 `.md` 会归入「未分类」。

## 常用快捷键

| 操作 | 快捷键 |
|------|--------|
| 新建笔记 | `⌘N` |
| 新建文件夹 | `⌘⇧N` |
| 刷新当前文件夹 | `⌘R` |
| 重命名所选文件夹 | `⌘⇧R` |
| 打开所选文件夹位置 | `⌘⇧O` |
| 查找 | `⌘F` |
| 查找与替换 | `⌘⌥F` |
| 查找下一个 / 上一个 | `⌘G` / `⌘⇧G` |
| 导出当前笔记为 PDF | `⌘E` |
| 导出当前文件夹为 PDF | `⌘⇧E` |
| 重启应用 | `⌘⌥R` |

## 项目结构

```
Moyan/
├── Moyan/                 # 应用源码（SwiftUI + AppKit）
│   ├── AI/                # Cursor AI 服务
│   ├── Models/            # 设置与笔记模型
│   ├── Store/             # 笔记库与编辑桥接
│   ├── Utilities/         # Markdown / PDF / WPS 等
│   └── Views/             # 界面
├── Moyan.xcodeproj/
├── Tools/cursor-bridge/   # Cursor SDK 桥接脚本
└── 运行墨言.command       # 启动已编译 Debug 包
```

## License

[AGPL-3.0](LICENSE)

# ZwZ — 轻量·安全·优雅的 macOS 压缩解压工具

<p align="center">
  <b>ZIP · RAR · 7Z · TAR.GZ · ZWZ</b><br>
  一个工具，搞定所有压缩格式
</p>

---

## 为什么选择 ZwZ？

### 🔐 军用级加密，隐私至上

ZwZ 自研的 **ZWZ 格式**采用 AES-256-GCM 认证加密——不仅加密文件内容，连同**文件名、路径、大小、时间戳、目录结构**全部隐藏。密码错误时，攻击者连压缩包里有什么都无从知晓。密码强度实时评估，弱密码即时提示。

### 🧩 全格式覆盖，一个就够

| 操作 | 支持格式 |
|------|----------|
| 压缩 | ZIP、ZWZ |
| 解压 | ZIP、RAR、7Z、TAR.GZ、TGZ、GZ、ZWZ |
| 预览 | 以上全部 |

无需安装多个解压工具，ZwZ 一站式解决。

### ⚡ 多线程并行，极速处理

大文件自动分块并行压缩/解压，线程数自适应 CPU 核心数。**10 MB 以上文件自动触发并行管线**，在多核 Mac 上榨干每一分性能。

### 🎨 macOS 原生体验，小清新美学

- **SwiftUI + AppKit 混合架构**——原生渲染，零跨平台损耗
- **粉蓝渐变主题**——压缩用蓝，解压用粉，视觉直觉
- **拖拽即用**——拖文件到窗口、拖到 Dock 图标、系统右键菜单
- **浏览器式标签页**——多任务并行，⌘T 新建、⌘1~9 切换
- **随系统深浅色自动切换**

### 🧠 智能解压规划

自动检测压缩包内文件结构：单文件直接提取、嵌套文件夹智能展平、多层目录自动合并——告别"解压出来又套一层文件夹"的烦恼。

### 💾 虚拟磁盘挂载

将压缩包挂载为虚拟磁盘，在 Finder 中直接浏览、修改，保存时写回——像操作普通文件夹一样操作压缩包。

### 🔑 密码保险箱

常用密码存入本地加密保险箱，主密码一键解锁，再也不用反复输入。

### 🌐 中英双语

所有界面、错误提示、通知实时切换中文/英文。

### 🖥️ CLI + GUI 双模驱动

```bash
# 命令行一键压缩
zwz compress ~/Documents/project

# 命令行解压
zwz extract archive.zip -o ~/output

# 预览压缩包内容
zwz list archive.rar
```

GUI 适合日常使用，CLI 适合脚本自动化和远程服务器。

---

## 架构设计

```
┌─────────────────────────────────────┐
│           ZwZ GUI (App)             │
│  SwiftUI · 标签页 · 拖拽 · 设置     │
├─────────────────────────────────────┤
│           ZwZ CLI (zwz)             │
│  命令行工具 · 脚本集成               │
├─────────────────────────────────────┤
│         ZwzCore (Library)           │
│  统一 API · 压缩 · 解压 · 预览 · 加密 │
├──────────┬──────────┬───────────────┤
│ ZIP (AES)│   RAR    │ 7Z / TAR.GZ   │
│ Foundation│SWCompr. │  SWCompression│
└──────────┴──────────┴───────────────┘
```

- **ZwzCore** — 纯 Swift 库，无 GUI 依赖，可独立集成到任何 Swift 项目
- **ZwzGUI** — macOS 原生应用，SwiftUI + AppKit 混合
- **zwz** — 命令行可执行文件

---

## 快速开始

### 环境要求

- macOS 15.0+
- Xcode 16.0+
- Swift 6.3

### 构建

```bash
git clone git@github.com:jiangzhiwan/ZwZ.git
cd ZwZ
swift build
```

### 运行 CLI

```bash
swift run zwz help
```

### 运行 GUI

```bash
swift run ZwzGUI
```

### 运行测试

```bash
swift test
```

---

## 技术亮点

| 特性 | 实现 |
|------|------|
| 加密 | AES-256-GCM 认证加密（CryptoSwift） |
| 压缩 | Deflate / LZMA / Store（Apple Compression） |
| ZIP 支持 | ZIPFoundation（AES 加密读写） |
| RAR/7Z/TAR | SWCompression（纯 Swift 解压） |
| 并行 | 大文件自动分块 + OperationQueue 多线程 |
| 取消 | CancellationToken 协作式取消，资源即时释放 |
| 分卷 | 压缩时按 MB/KB 自动分割输出 |
| 文件关联 | 系统级文件类型注册，双击即开 |
| 持久化 | UserDefaults + 标签页状态自动恢复 |
| 国际化 | 零外部依赖的中英双语方案 |

---

## 项目结构

```
ZwZ/
├── Sources/
│   ├── ZwzCore/          # 核心库：压缩/解压/加密/预览
│   ├── ZwzGUI/           # macOS GUI 应用
│   └── zwz/              # 命令行工具
├── Tests/
│   ├── ZwzCoreTests/     # 核心库单元测试
│   └── ZwzGUITests/      # GUI 单元测试
├── Packaging/            # App 图标、安装脚本
├── scripts/              # 构建/打包脚本
├── docs/                 # 设计文档
└── Package.swift         # SPM 清单
```

---

## 许可

MIT License

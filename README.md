# ZwZ — 轻量·安全·优雅的 macOS 压缩解压工具

<p align="center">
  <b>ZIP · RAR · 7Z · TAR.GZ · ZWZ</b><br>
  一个工具，搞定所有压缩格式
</p>

---

## 为什么选择 ZwZ？

### 🔐 标准认证加密，隐私优先

ZWZ 使用 AES-256-GCM 认证加密保护归档内容。加密归档会同时保护文件名、路径、大小、时间戳和目录结构；无加密模式则不会隐藏这些元数据。密码强度会在界面中即时提示。

### 🧩 全格式覆盖，一个就够

| 操作 | 支持格式 |
|------|----------|
| 创建 | ZIP、ZWZ |
| 解压 | ZIP、RAR、7Z、TAR.GZ、TGZ、GZ、ZWZ |
| 预览 | 上述格式（能力取决于系统工具与归档内容） |

ZIP 和 ZWZ 支持写入；RAR、7Z、TAR.GZ、TGZ、GZ 主要用于读取、解压和预览。RAR/7Z 的部分能力需要系统中可用的 `unar`、`unrar` 或 `7z` 等工具。

### ⚡ 多线程并行，极速处理

ZWZ 按块处理数据，ZIP 对多个文件进行并行预读；线程数可按路径自动选择，也可以手动配置。不同格式使用不同的压缩和解压管线。

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
zwz extract archive.zip ~/output

# 预览压缩包内容
zwz list archive.rar
```

GUI 适合日常使用，CLI 适合脚本自动化和远程服务器。

### 🗂️ 归档预览、编辑与批量重命名

主界面提供浏览器式标签页、归档内搜索和预览侧栏；文本、图片和视频预览均设置了资源上限。ZIP/ZWZ 归档可进入编辑工作流，执行重命名、删除和保存。

批量重命名支持查找替换、前后缀、序号/模板、正则替换和大小写转换，应用前会显示预览，名称冲突自动编号。GUI 与 CLI 共用同一套规则引擎：

```bash
# 仅预览，不修改归档
zwz rename archive.zip --rule find-replace \
  --find draft --replace final --dry-run

# 添加前缀，并只处理匹配的顶层条目
zwz rename archive.zwz --rule prefix-suffix \
  --prefix 2026- --filter '*.txt'
```

---

## ZWZ V3 公钥加密与签名

ZWZ 支持无加密、密码加密和公钥加密三种模式。密码与公钥模式互斥；公钥模式可以同时选择多个接收方，并可选择一个本机身份进行 Ed25519 签名。任一接收方持有匹配的 X25519 私钥即可解密，文件内容、文件名、路径、大小、时间戳和目录结构均由 AES-256-GCM 认证加密保护。

### GUI

- 在“设置 > 密钥”中创建本机身份、导入或导出公开身份，以及备份或恢复私钥。
- 创建 ZWZ 压缩包时可选择无加密、密码或公钥模式；公钥模式支持多个接收方和一个可选的本机签名身份。
- 接收方名称与指纹是压缩包中的公开标签，未经过信任验证，不能单独证明接收方身份。
- 签名状态区分“已知签名者且签名有效”“未知签名者但签名有效”“未签名”和“签名无效”。签名无效时，预览、解压、单项打开、编辑和虚拟磁盘挂载都会被拒绝。
- 缺少匹配私钥时，可恢复 `.zwzkey` 私钥备份并重试原操作。编辑或虚拟磁盘保存公钥压缩包时会保留原接收方与签名保护，不会静默降级。

### CLI

```bash
# 创建本机身份并导出公钥
zwz key create "My Mac"
zwz key export-public "My Mac" recipient.zwzpub

# 接收方先导入公钥；--recipient 接受已导入的名称或指纹，不接受文件路径
zwz key import-public recipient.zwzpub
zwz compress -f zwz --recipient "Recipient Name" --sign "My Mac" source shared.zwz

# 解压时自动从本机身份中寻找匹配私钥
zwz extract archive.zwz output

# 私钥备份与恢复，密码通过隐藏的终端输入读取
zwz key backup "My Mac" identity.zwzkey
zwz key restore identity.zwzkey
```

可重复使用 `--recipient <name-or-fingerprint>` 添加多个接收方。`--sign` 只能选择本机身份，并且必须与至少一个 `--recipient` 一起使用。密码加密使用 `--password`，不能与 `--recipient` 或 `--sign` 同时使用。

### ZwzCore 接口

`CompressionOptions.encryption` 提供 `.none`、`.password` 和 `.publicKey`。公钥压缩、列表与解压通过带 `ZwzPrivateKeyProvider` 的 `ZwzAPI` 重载完成，并返回包含格式版本、加密类型、接收方指纹和结构化签名状态的结果。`ZwzAPI.inspect` 可在请求私钥及解密索引前读取公开接收方标签并验证可选签名。

### 密钥与兼容性

- 生产环境中的私钥保存在 macOS 钥匙串，并使用“用户在场”访问控制；每次解密或签名都会要求 Touch ID 或 Mac 登录密码确认。
- `.zwzkey` 私钥备份使用 scrypt（N=65,536、r=8、p=1）派生密钥并由 AES-256-GCM 保护，必须设置独立密码。请至少保留一份可用私钥或加密备份；如果所有匹配私钥及备份均丢失，公钥加密内容将永久无法恢复。
- ZWZ V2 无加密和密码加密压缩包继续支持检测、预览、列表和解压。
- ZWZ V1 只能被安全检测并报告为不支持；本项目没有可验证的历史 V1 读写器或真实兼容 fixture，因此不声明 V1 解压兼容。

---

## 架构设计

```
┌─────────────────────────────────────────┐
│             ZwZ GUI (App)               │
│     SwiftUI · 标签页 · 预览 · 编辑       │
├─────────────────────────────────────────┤
│             ZwZ CLI (zwz)               │
│       压缩 · 解压 · 列表 · 批量重命名     │
├─────────────────────────────────────────┤
│              ZwzCore (Library)          │
│   统一 API · 格式编解码 · 压缩/解压 · 加密 │
├─────────────────────────────────────────┤
│ ZIPFoundation · SWCompression · CryptoSwift │
└─────────────────────────────────────────┘
```

- **ZwzGUI** — macOS 原生应用，负责界面、工作区和交互流程
- **zwz** — 命令行可执行文件，负责脚本入口和身份管理命令
- **ZwzCore** — 统一承载归档格式、加密、解压、预览、编辑与工作流能力

---

## 快速开始

### 环境要求

- macOS 15.0+
- 支持 Swift 6.3 的 Xcode 或 Swift toolchain

### 构建

```bash
git clone git@github.com:jiangzhiwan/ZwZ.git
cd ZwZ
swift build
swift run zwz help
swift run ZwzGUI
swift test
./build-app.command
./build-installer.command
```

---

## 技术亮点

| 特性 | 说明 |
|------|------|
| 归档保护 | ZWZ 支持 AES-256-GCM 认证加密、公钥接收方和可选签名 |
| 签名 | 可选 Ed25519，区分已知、未知、未签名和无效状态 |
| 压缩 | Deflate、LZMA、Store 等路径按格式选择 |
| ZIP I/O | ZIPFoundation 负责 ZIP 读写；具体加密能力取决于归档与系统工具 |
| RAR/7Z/TAR | 以读取、解压和预览为主，必要时调用系统工具 |
| 并发 | ZWZ 按块处理；ZIP 对多个文件进行并行预读；线程数可自动选择或配置 |
| 编辑 | 归档条目重命名、删除、保存和批量重命名预览 |
| 取消 | `CancellationToken` 协作式取消并及时清理资源 |
| 分卷 | 支持按 MB/KB 设置分卷大小 |
| 文件关联 | 系统级文件类型注册，双击即开 |
| 持久化 | UserDefaults + 标签页状态自动恢复 |
| 国际化 | 零外部依赖的中英双语方案 |

---

## 项目结构

```text
ZwZ/
├── Sources/
│   ├── ZwzCore/          # 核心库：格式、加密、预览与工作流
│   ├── ZwzGUI/           # macOS GUI 应用
│   └── zwz/              # 命令行工具
├── Tests/                # Core / GUI / CLI 测试
├── Packaging/            # App 图标、安装脚本
├── scripts/              # 构建/打包脚本
├── docs/                 # 设计文档
└── Package.swift         # SPM 清单
```

---

## 许可

使用GPL V3开源协议

# ZWZ V3 公钥加密开发进度与模型交接

更新时间：2026-07-13 17:18（Asia/Shanghai）

## 当前结论

项目将保留现有 ZWZ V1、V2 的读取与密码加密兼容，独立新增 ZWZ V3。V3 采用多接收方 X25519 密钥封装、AES-256-GCM 内容加密和可选 Ed25519 签名。

需求与设计已经用户逐项确认，设计文档和实施计划均已提交。Task 1 至 Task 10 已全部完成、测试、打包并通过独立代码审查。ZWZ V3 公钥加密项目实施完成。

## 已确认需求

- 仅用于 `.zwz` 格式，扩展名不变。
- 公钥加密、私钥解密。
- 一个压缩包支持多个接收方，任意对应私钥均可解密。
- ZwZ 内置生成和管理密钥对。
- 支持公钥导入导出，以及密码加密的私钥备份和恢复。
- 私钥默认保存到 macOS 钥匙串；每次解密或签名必须通过 Touch ID 或 Mac 登录密码确认。
- 仅要求 ZwZ 应用之间兼容。
- 密码模式和公钥模式二选一。
- GUI、CLI、ZwzCore 公共 API 同时覆盖。
- 压缩包允许公开显示接收方名称和指纹。
- 身份必须由用户手动创建并命名。
- 缺少匹配私钥时，引导导入私钥备份后自动继续。
- 必须继续支持现有 V1、V2 无密码和密码加密压缩包。
- 支持可选发送方签名；签名者公钥与指纹嵌入压缩包，并区分已知/未知签名者。

## 文档与提交

- `b9608dc` — `docs: design public key encryption for ZWZ`
- `664f19a` — `docs: plan ZWZ public key encryption`
- `6ba4f7e` — `docs: preserve ZWZ v2 alongside public key v3`

设计文档：`docs/superpowers/specs/2026-07-12-public-key-encryption-design.md`

实施计划：`docs/superpowers/plans/2026-07-12-public-key-encryption.md`

## 基线验证

实现前完整运行 `swift test`：

- 178 项测试通过；
- 1 项因缺少桌面 RAR 测试文件而跳过；
- 0 失败；
- 总耗时约 232 秒。

## Task 1：公共类型与加密模式兼容（已完成）

提交：`7d5079a feat: add explicit ZWZ encryption modes`

完成内容：

- 新增 `ZwzEncryptionMode`：`.none`、`.password`、`.publicKey`。
- 公钥模式强制至少一个接收方。
- 新增接收方、签名身份、签名验证、安全信息和 V3 错误类型。
- 保留既有 `CompressionOptions(password:)` 源兼容，并映射到显式模式。
- 新显式初始化入口从类型层面避免同时传入密码和接收方。

验证：

- `ZwzV3TypesTests`：5/5 通过。
- 补充兼容复核 `ZwzV2APITests`：5/5 通过。
- `ZwzHiddenFilePreviewTests`：2/2 通过。
- 独立审查结论：Approved。

审查遗留的非阻断建议：最终阶段可增加 raw value、全部安全错误描述及非空接收方成功路径的契约测试。

## Task 2：密码学原语与多接收方封装（已完成）

提交：

- `86067f0 feat: add ZWZ recipient wrapping and signatures`
- `c2636b0 fix: domain-separate ZWZ key fingerprints`

完成内容：

- X25519 多接收方密钥封装。
- 每次 `wrap` 只生成一个临时 X25519 密钥对，所有接收方共享临时公钥。
- 每位接收方使用独立随机 12 字节 AES-GCM nonce。
- HKDF-SHA-256 派生 256 位封装密钥。
- AAD 规范绑定固定域、archive UUID 原始 16 字节、长度前缀接收方指纹和临时公钥。
- Ed25519 签名及验证。
- wrong recipient、nonce/ciphertext/tag/AAD 篡改统一返回安全错误，不泄漏底层密码信息。
- 指纹规范显式域分离：V3 版本域、X25519 agreement 公钥域、Ed25519 signing 公钥域；所有字段使用 UInt32 大端长度前缀。
- 固定 SHA-256 测试向量锁定跨实现指纹稳定性。

验证：

- 初版定向密码学测试：6/6 通过。
- 修复后 `ZwzV3CryptoTests`：7/7 通过。
- 初版提交时完整 `swift test` 退出码 0。
- 第一轮审查发现指纹缺少明确算法用途域，已修复。
- 第二轮独立审查：Approved，无 Critical、Important 或 Minor 问题。

## Task 3：V3 二进制容器（已完成）

提交：`d6514a9`、`8469822`。已完成 160 字节固定头、绝对 little-endian offset、连续区域、接收方/签名者记录、规范签名字节、checked arithmetic 与独立黄金字节向量。`ZwzV3BinaryCodecTests` 10/10 通过；独立首审与补强复审均 Approved，无剩余问题。

残余架构注意：当前 `parse(Data)` 会复制 data/index/canonical 数据，超大合法归档存在多份线性内存占用；Task 4 接入文件读取时应设置上层限额或采用切片/流式路径。

## Task 4：V3 压缩、预览与解压（已完成）

提交：`a32a7ea`、`ce77625`。已完成块与索引认证加密、多接收方、签名先验验证、完整/单项提取、取消清理、原子替换和分卷。首审发现的签名者指纹冒充、checked arithmetic 与无限制整包读取问题已修复；当前采用 512 MiB 逻辑归档预算。`swift test --filter ZwzV3` 44/44 通过，完整 `swift test` 222 项执行、1 跳过、0 失败，复审 Approved。

## Task 5：密钥文件、私钥备份与身份存储（已完成）

提交：`674e31d`、`6715d62`。已完成 `ZWZP` 公钥文件、scrypt + AES-GCM `ZWZB` 私钥备份、内存存储和 `.userPresence` Keychain 存储。首审发现的替换丢私钥、并发事务交错和删除首错停止问题已修复。Codec 7/7、Store 11/11、既有 V3 44/44 通过，复审 Approved。真实 Keychain 系统提示仍需签名 App 手工验证。

## Task 6：接入现有 ZwzCore 公共 API（已完成）

提交：`8960d7f`、`035413c`。已完成 V2/V3 逻辑 magic 分发、keyProvider 公共重载、结构化安全结果、错误原样穿透和旧 API 兼容。裸 `.bin` V3 与 V2/V3 超过 100 卷均通过公共 API。Task 6 14/14、V2 API 5/5，复审 Approved。V1 因缺少历史实现/fixture 继续明确 unsupported。

## Task 7：CLI 密钥管理与公钥工作流（已完成）

提交：`74d6d7b`、`7b140e8`。已完成 8 个 key 子命令、多接收方与签名解析、身份唯一解析、TTY/stdin 备份密码、原子输出、缺钥匙恢复指引、签名状态和实际 V3/ZIP/V2 CLI 往返。CLI 16/16、recipientInfo 4/4、V3 API 14/14、V2 API 5/5，help smoke 通过，复审 Approved。

## Task 8：GUI 密钥管理（已完成，当前暂停点）

提交：`7d51a20 feat: add ZWZ key management interface`。设置中新增公私钥页面，分区管理本机身份与公钥联系人，覆盖创建、重命名、指纹复制、公钥导入导出、两阶段删除、加密私钥备份和恢复。Keychain/scrypt 与密钥文件 I/O 均离开主线程；密码只保存在 SwiftUI `SecureField` 状态并在成功、取消、页面消失和认证失败时清理。冲突默认要求确认，显式替换绑定对应指纹与独立持有的数据；恢复成功回调只执行一次。文件读取执行 16 MiB 前后校验，输出仅在面板确认目标后原子写入。

首审发现的 3 个 Important（mutation 成功后列表刷新失败被误报、同步操作期间虚假取消、异步文件读取与冲突数据竞态）均已修复。`IdentityManagerViewModelTests` 19/19、`WorkspaceSettingsTests` 1/1、`swift build --target ZwzGUI` 通过；终审 Approved，无剩余 Critical/Important/Minor。审查差异包：`.superpowers/sdd/v3-task-8-review.diff`。

手工验证限制：真实 Keychain 系统提示、Touch ID、Mac 登录密码回退及用户取消映射仍必须在签名 App 中验证，不能由 `swift test` 安全执行。

## Task 9：GUI 公钥压缩、预览、解压、编辑与虚拟磁盘（已完成）

提交：`1ccdd9b feat: integrate public-key archives in GUI`

完成内容：

- 应用级唯一 `ZwzGUIIdentityStore.shared` 贯穿设置、压缩、列表、解压、单项预览、编辑和虚拟磁盘；测试使用可注入内存替身；
- 新增 V3 只读公开检查 API，在查找私钥或解封内容密钥前显示接收方并验证签名，覆盖已知、未知、无签名和无效四种状态；
- GUI 支持无加密、密码和公钥三种模式，公钥模式仅限 ZWZ，接收方确定性排序且签名者仅限本机身份；
- 缺少匹配私钥时显示归档公开接收方并进入私钥备份恢复，一次成功恢复只重试一次，不形成自动循环；
- 无效签名在预览、解压、智能解压、单项打开/拖拽、编辑和挂载的方法边界统一阻断；
- 编辑和虚拟磁盘保存以打开时的会话保护配置为准，必须保留全部接收方与原签名，否则明确拒绝，绝不降级；
- 原签名同时绑定声明指纹与实际 Ed25519 公钥，阻止未知签名者冒用本机指纹后在重建时被“升级”为已知签名者；
- 虚拟磁盘持久化会话不保存密码、私钥或认证上下文；重启恢复密码归档时重新提示并验证原密码；旧 JSON 只迁移非敏感的“需要密码”保护标记；
- 编辑打开加入会话与 ViewModel 双重 generation/source 校验，源切换后迟到回调不能重新安装旧编辑会话。

验证与审查：

- `ZwzV3ArchiveInspectionTests`：8/8 通过；
- `PublicKeyArchiveWorkflowTests`：20/20 通过；
- 全部 `ZwzGUITests`：131/131 通过；
- `ZwzV2APITests` + `ZwzV3APITests`：19/19 通过；
- `swift build --target ZwzGUI`：通过；
- 独立首审发现 5 个 Important，首次复审与最终复审又发现 2 个 V2 密码会话迁移问题，全部修复后终审 Approved，无剩余 Critical/Important；
- 审查差异包：`.superpowers/sdd/v3-task-9-review.diff`。

手工验证限制：签名 App 中的真实 Keychain/Touch ID 提示、虚拟盘恢复密码弹窗和 `hdiutil` 挂载/保存仍需实际环境验证。

## Task 10：全量回归、兼容样本、文档与打包（已完成）

提交：`42a1ff7 docs: document ZWZ public-key encryption`

完成内容：

- 提交 5 个 SHA-256 锁定的小型固定样本：V1 检测头、V2 无密码/密码、V3 无签名/签名双接收方；
- 新增兼容测试，覆盖检测、公开检查、列表、解压、V3 两位接收方、已知/未知签名、V2 错误密码，以及签名规范字节和认证密文单字节篡改拒绝；
- fixtures 作为 SwiftPM 测试资源复制，固定私钥和密码均明确标注为 TEST-ONLY；
- README 补齐真实 GUI、CLI、ZwzCore 公钥工作流和安全说明，并明确 V2 兼容、V1 仅检测且不支持解压；
- bundle 检查覆盖可执行文件、Info.plist、图标、Logo、SwiftPM 资源包、所有用户权限、签名前预检和签名后严格验证；
- 成功生成 `dist/ZwZ.app`、`dist/ZwZ.dmg` 和 `dist/ZwZ-Installer.pkg`。

最终验证与审查：

- `ZwzV3CompatibilityTests`：8/8 通过；
- 最终完整 `swift test`：346 项执行、1 项因既有桌面 RAR fixture 缺失跳过、0 失败，约 440.5 秒；
- App/DMG 打包、签名后 bundle 检查和 Installer PKG 打包全部通过；
- 独立终审发现 2 个 Important（Unix 权限位校验不完整、fixtures 未声明为测试资源），全部修复；
- 正向签名包通过，`0604` 资源、`0700` 可执行文件、`0704` 目录负向样本均被准确拒绝；
- 最终复审 Approved，无 Critical、Important 或 Minor；
- 审查差异包：`.superpowers/sdd/v3-task-10-review.diff`。

发布限制：未实际安装 PKG；当前产物为 ad-hoc 签名且未公证；真实 Touch ID/Mac 登录密码及 `hdiutil` 交互仍需签名 App 手工验证。

## 实施状态

Task 1 至 Task 10 全部完成，无剩余计划内开发任务。

## 子代理驱动流程要求

用户选择了“子代理分任务执行”。后续应继续：

- 每个 Task 使用新的实现子代理；
- 实现者先读对应 task brief，并使用 TDD；
- 每个 Task 提交后生成独立 diff review package；
- 再用独立审查子代理同时检查规格符合性和代码质量；
- Important/Critical 问题必须回给实现者修复并重新审查；
- 审查通过才进入下一 Task；
- 进度追加到 `.superpowers/sdd/progress.md` 的 `ZWZ V3 Public-Key Encryption` 小节。

## 工作区注意事项

当前直接在 `main` 工作区开发，用户明确拒绝创建隔离 worktree，并授权在实现需要时修改现有未提交文件。

工作区在本功能开始前已有其他未提交的预览侧栏改动，包括：

- `Sources/ZwzCore/ArchiveExtractor.swift`
- `Sources/ZwzCore/ZwzExtractor.swift`
- `Sources/ZwzGUI/Localization.swift`
- `Sources/ZwzGUI/ZwzApp.swift`
- `Tests/ZwzGUITests/ArchiveViewModelSearchTests.swift`
- 若干 `ArchiveEntryPreview*` 新文件及对应测试/文档。

不要清理或丢弃这些文件。用户允许在公钥功能确有需要时继续修改它们，但每个任务提交前仍应检查 staged diff，避免把无关内容意外混入。

`.superpowers/sdd/` 下存在 Task brief、实现报告和 review diff，它们是短期交接资料，不应加入产品提交。

## 推荐恢复入口

切换模型后，可让新模型先读取：

1. 本进度文件；
2. `docs/superpowers/specs/2026-07-12-public-key-encryption-design.md`；
3. `docs/superpowers/plans/2026-07-12-public-key-encryption.md`；
4. `.superpowers/sdd/progress.md`；
5. `.superpowers/sdd/v3-task-9-brief.md`；
6. `.superpowers/sdd/v3-task-9-review.diff`；
7. `Sources/ZwzGUI/ArchiveViewModel.swift`；
8. `Sources/ZwzGUI/ArchiveEncryptionResolver.swift`；
9. `Tests/ZwzGUITests/PublicKeyArchiveWorkflowTests.swift`。

ZWZ V3 公钥加密实施已完成。后续仅需发行签名、公证、PKG 实际安装和真实 Keychain/Touch ID/虚拟磁盘手工验收。

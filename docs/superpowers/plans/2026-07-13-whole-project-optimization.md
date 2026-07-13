# ZwZ Whole-Project Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not dispatch subagents and do not create Git commits.

**Goal:** 深度优化 ZwZ 的全部产品代码，同时严格保持 GUI、CLI、公共 API、配置、安全语义和归档确定性字节不变。

**Architecture:** 采用审计驱动的分层实施：先建立契约与 Release 性能保护网，再按 `ZwzCore`、`zwz`、`ZwzGUI` 的依赖顺序优化，最后逐文件整理并进行全量兼容、安全、性能和人工验收。每个优化必须由测试、静态证据或可重复基准支撑；不能证明安全或收益的改动不进入产品代码。

**Tech Stack:** Swift 6.3、Swift Package Manager、SwiftUI、AppKit、Foundation、CryptoKit、CryptoSwift、ZIPFoundation、SWCompression、XCTest。

## Global Constraints

- 保持 GUI 操作与外观、CLI 命令与输出文本、`ZwzCore` 公共 API、配置数据及既有归档兼容性。
- 归档输出的所有可确定部分必须逐字节一致；随机字段保持现有协议、参数和分布。
- 不新增、替换或升级第三方依赖。
- 不提高 macOS 15.0、Xcode 16.0、Swift 6.3 的最低要求；没有主动降低版本的交付要求。
- 产品优化范围仅为 `Sources`；测试只用于保护和度量。
- 保留并纳入当前未提交的批量重命名功能。
- 允许深度内部重构、文件拆分和删除已证明无作用的死代码，但公共符号不改名。
- 有充分证据的缺陷和安全问题可修复；有行为争议时停止并一次询问用户一个问题。
- Release 性能优先；允许为明显速度收益增加内存，但不得引入大文件内存耗尽风险。
- 全部改动留在当前工作区，不创建分支、不暂存、不提交。

---

### Task 1: Freeze the Observable-Behavior Baseline

**Files:**
- Modify: `Tests/ZwzCoreTests/` 中与确定性编码、公共 API 和错误契约对应的现有测试文件
- Modify: `Tests/ZwzCLITests/CLIArgumentsTests.swift`
- Modify: `Tests/ZwzCLITests/ZwzCLIRunnerTests.swift`
- Modify: `Tests/ZwzGUITests/` 中与持久化和状态转换对应的现有测试文件
- Create only if existing suites cannot express the contract: `Tests/ZwzCoreTests/ProductCompatibilityContractTests.swift`

**Interfaces:**
- Consumes: 当前 `ZwzCore` 公共 API、`CLIArguments.parse(_:)`、`ZwzCLI.run(_:dependencies:)`、GUI snapshot/state 类型。
- Produces: 对后续所有任务生效的兼容性保护网；不产生新的产品接口。

- [ ] **Step 1: Record the clean behavioral baseline**

Run:

```bash
swift test
swift build -c release
```

Expected: 当前基线为 396 tests executed、1 skipped、0 failures；Release build exits 0。若数量因新增保护测试增加，只允许通过数增加，既有跳过不得增加。

- [ ] **Step 2: Inventory public and serialized contracts**

Run:

```bash
rg -n '^public |public (struct|enum|class|protocol|func|var|let|init)' Sources/ZwzCore
rg -n 'Codable|UserDefaults|JSONEncoder|JSONDecoder|PropertyList' Sources/ZwzGUI
rg -n 'output\(|errorOutput\(|CLIParseError|exitCode' Sources/zwz
```

Expected: produce a checklist in the task notes mapping every public API family, persisted model, CLI command, error output path, and exit path to an existing test or a new contract test.

- [ ] **Step 3: Add missing contract tests before refactoring**

For each uncovered contract, write a focused XCTest that captures the exact current result. Use byte equality for deterministic codecs, exact string equality for CLI output, exact encoded `Data` equality for persisted models, and concrete error-type matching rather than `XCTAssertThrowsError` alone. CLI contract tests must call the existing `CLITestHarness.run(_:)` test seam, then compare `output.values`, `errors.values` and the returned `Int32` exactly; do not introduce a second dependency harness.

Expected: each new test passes against the untouched implementation; a test that cannot distinguish changed behavior is tightened before proceeding.

- [ ] **Step 4: Re-run the contract suites**

Run:

```bash
swift test --filter ZwzCoreTests
swift test --filter ZwzCLITests
swift test --filter ZwzGUITests
```

Expected: 0 failures and only the existing RAR fixture skip.

### Task 2: Establish Reproducible Release Performance and Memory Baselines

**Files:**
- Create: `Tests/ZwzCoreTests/ReleasePerformanceTests.swift`

**Interfaces:**
- Consumes: existing `ZwzAPI` compression, listing, preview, extraction and single-entry APIs.
- Produces: opt-in Release benchmarks with deterministic fixture generation and recorded wall-time/peak-memory results; no product API.

- [ ] **Step 1: Add deterministic fixture generation**

Implement a test-only fixture factory using a fixed-seed byte generator and fixed modification timestamps. It must create: 10,000 small files, one large compressible file, one large incompressible file, deep Unicode/hidden paths, and split-archive input. Do not use `SystemRandomNumberGenerator`.

```swift
struct DeterministicBytes {
    private var state: UInt64 = 0x5A57_5A42_454E_4348

    mutating func next() -> UInt8 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 32)
    }
}
```

- [ ] **Step 2: Add opt-in Release measurement cases**

Add XCTest cases gated by `ZWZ_RUN_PERFORMANCE_TESTS=1`. Measure compression, listing, preview, single-entry extraction and full extraction for ZIP, ZWZ V2 and ZWZ V3 where supported. Keep passwords and test keys fixed and conspicuously test-only.

```swift
try XCTSkipUnless(ProcessInfo.processInfo.environment["ZWZ_RUN_PERFORMANCE_TESTS"] == "1")
measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
    // Invoke exactly one existing public workflow per measurement block.
}
```

- [ ] **Step 3: Capture the pre-change Release baseline**

Run:

```bash
ZWZ_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter ReleasePerformanceTests
```

Expected: all benchmark cases pass and emit duration/memory measurements. Record median wall time and peak memory for each scenario in task notes before modifying product code.

- [ ] **Step 4: Verify benchmark isolation**

Run:

```bash
swift test --filter ReleasePerformanceTests
```

Expected: every performance case is skipped without `ZWZ_RUN_PERFORMANCE_TESTS=1`; normal test duration is not materially increased.

### Task 3: Audit Every Product File and Lock the Change Map

**Files:**
- Inspect: every `.swift` file under `Sources/ZwzCore`, `Sources/zwz`, `Sources/ZwzGUI`, and `Sources/testDebug`
- Modify: no product files in this task

**Interfaces:**
- Consumes: Task 1 contracts and Task 2 baseline.
- Produces: a task-local change map classifying every product file as `performance`, `structure`, `safety`, `style`, or `reviewed-no-change`, with evidence for each planned edit.

- [ ] **Step 1: Generate the complete source inventory**

Run:

```bash
rg --files Sources -g '*.swift' | sort
find Sources -name '*.swift' -print0 | xargs -0 wc -l | sort -nr
```

Expected: every product Swift file appears exactly once in the review checklist; large files are reviewed first but no file is omitted.

- [ ] **Step 2: Locate measurable hot-path risks**

Run:

```bash
rg -n 'Data\(contentsOf:|readToEnd\(|subdata\(|Data\([^)]*\[|contentsOfDirectory|enumerator\(|sorted\(|map\(|flatMap\(|reduce\(' Sources
rg -n 'DispatchQueue|Task\s*\{|OperationQueue|NSLock|withLock|@MainActor|DispatchSemaphore' Sources
rg -n 'try\?|catch \{|fatalError|precondition|assert\(' Sources
```

Expected: each match is classified as safe/necessary or linked to a concrete optimization candidate; search output alone is not treated as proof.

- [ ] **Step 3: Map file responsibilities and split candidates**

For every file over 500 lines, list its independent responsibilities and existing tests. A split is permitted only when extracted code has a clear interface and can be validated without changing public visibility. Prioritize `ZwzApp.swift`, `ArchiveViewModel.swift`, `ArchiveExtractor.swift`, `IdentityManagerView.swift`, `CLIArguments.swift`, and the V3 compressor/extractor/codec files.

- [ ] **Step 4: Reject unsupported edits**

Remove from the change map any proposed edit that has no measurable benefit, no structural clarity benefit, changes a public symbol, changes deterministic output, or lacks a feasible regression test. Mark the corresponding file `reviewed-no-change` with the reason.

### Task 4: Optimize Shared Core I/O, Path Handling, and Resource Lifetimes

**Files:**
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ArchiveExtractor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ArchivePreviewer.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZwzExtractor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZipCompressor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZwzCompressor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ArchiveEntryPresentation.swift`
- Modify corresponding focused tests under `Tests/ZwzCoreTests`

**Interfaces:**
- Consumes: existing `ArchiveEntry`, `CompressionOptions`, `CancellationToken`, preview/list/extract APIs.
- Produces: the same signatures and results with reduced redundant traversal, allocation or I/O; helper types remain internal.

- [ ] **Step 1: Add a failing regression or characterization test for each candidate**

Before each product edit, add one test that captures ordering, hidden-file behavior, progress, cancellation cleanup, overwrite behavior and exact errors relevant to that edit. For path/list transformations, compare complete ordered arrays rather than sets.

- [ ] **Step 2: Run the focused test and verify its sensitivity**

Run the exact containing suite, for example:

```bash
swift test --filter ArchiveEntryPresentationTests
swift test --filter ArchiveEntryPreviewExtractionTests
swift test --filter OperationCancellationTests
```

Expected: a newly added bug-regression test fails for the identified defect; a characterization test passes before refactoring and must be mutation-checked by temporarily changing its expected ordering/error value, then restoring it.

- [ ] **Step 3: Apply the smallest evidence-backed I/O change**

Use bounded reads, reuse already parsed metadata, avoid repeated directory traversal, and scope file handles with `defer` where Task 3 shows duplication. Do not replace streaming paths with whole-file `Data`. Preserve exact callbacks and error mapping.

- [ ] **Step 4: Run focused and core regression suites**

Run:

```bash
swift test --filter ZwzCoreTests
ZWZ_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter ReleasePerformanceTests
```

Expected: 0 failures; affected Release cases improve or remain within run-to-run noise without increased large-file memory risk. Revert any unsupported optimization.

### Task 5: Optimize ZWZ V2 Pipelines Without Changing Bytes

**Files:**
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV2/ZwzV2Extractor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- Modify as supported by Task 3 evidence: remaining files in `Sources/ZwzCore/ZWZV2/`
- Modify corresponding `Tests/ZwzCoreTests/ZWZV2/` suites

**Interfaces:**
- Consumes: current V2 header/block/index codecs and public adapter paths.
- Produces: byte-compatible V2 archives and identical errors/progress with optimized buffering, scheduling or parsing.

- [ ] **Step 1: Lock deterministic V2 output**

Add a fixture test that normalizes input timestamps, writes an unencrypted V2 archive with fixed options, and compares the complete output `Data` or SHA-256 to the pre-change value. For password mode, inject the existing deterministic crypto test seam where available and compare every deterministic region.

- [ ] **Step 2: Verify the byte lock passes before edits**

Run:

```bash
swift test --filter ZwzV2BinaryCodecTests
swift test --filter ZwzV2RoundTripTests
swift test --filter ZwzV2APITests
```

Expected: 0 failures and the new deterministic-output assertion passes.

- [ ] **Step 3: Optimize only measured V2 bottlenecks**

Tune ordered-block scheduling, buffer reuse, range reads or index parsing only where profiling shows cost. Keep compression codec choice, threshold decisions, block sizes, record ordering, nonce derivation, checksums and little-endian encoding unchanged.

- [ ] **Step 4: Validate V2 compatibility, security and performance**

Run:

```bash
swift test --filter ZwzV2
ZWZ_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter ReleasePerformanceTests
```

Expected: all V2 tests pass; deterministic hashes are unchanged; wrong-password, corruption, traversal and cancellation behavior remains concrete; measured V2 paths do not regress beyond noise.

### Task 6: Optimize ZWZ V3 Pipelines Without Weakening Security

**Files:**
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV3/ZwzV3Compressor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV3/ZwzV3Extractor.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV3/ZwzV3BinaryCodec.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV3/ZwzV3ArchiveCodec.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZWZV3/MacKeychainIdentityStore.swift`
- Modify corresponding `Tests/ZwzCoreTests/ZWZV3/` suites

**Interfaces:**
- Consumes: existing V3 recipient wrapping, signatures, canonical bytes, archive inspection, identity stores and public adapters.
- Produces: identical public signatures and canonical encoding with reduced copies/contention and preserved authentication order.

- [ ] **Step 1: Extend canonical-byte and mutation protection where needed**

Ensure tests cover fixed header bytes, recipient order, signature canonical bytes, every authenticated region, missing/wrong key distinction, cancellation cleanup, split-volume discovery and the 512 MiB logical archive budget before editing relevant paths.

- [ ] **Step 2: Run V3 safety baseline**

Run:

```bash
swift test --filter ZwzV3BinaryCodecTests
swift test --filter ZwzV3SecurityTests
swift test --filter ZwzV3CompatibilityTests
swift test --filter ZwzIdentityStoreTests
```

Expected: 0 failures.

- [ ] **Step 3: Optimize measured V3 bottlenecks**

Reduce avoidable `Data` copies, reuse validated parsed structures, bound reads and narrow synchronization only where Task 3 and Release measurement agree. Preserve signature-before-key-lookup behavior, fingerprint domains, algorithms, recipient order, random field sizes, AAD, canonical bytes, authentication failures and user-presence semantics.

- [ ] **Step 4: Validate all V3 and public API paths**

Run:

```bash
swift test --filter ZwzV3
swift test --filter PublicKeyArchiveWorkflowTests
ZWZ_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter ReleasePerformanceTests
```

Expected: 0 failures; committed fixture hashes remain locked; security mutation tests still fail safely; measured V3 paths improve or remain within noise.

### Task 7: Refactor Core API and Utility Boundaries

**Files:**
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZwzAPI.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/Types.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/ZwzFormat.swift`
- Modify as supported by Task 3 evidence: `Sources/ZwzCore/BatchRename.swift`
- Modify remaining reviewed `Sources/ZwzCore/*.swift` files
- Modify corresponding tests under `Tests/ZwzCoreTests`

**Interfaces:**
- Consumes: optimized internal V2/V3/shared workflows from Tasks 4–6.
- Produces: unchanged public API surface with smaller internal responsibilities and consolidated private helpers.

- [ ] **Step 1: Add compile-shape tests for public overloads**

Call every legacy and current public initializer/overload from tests with explicit types, including password and key-provider variants. The test succeeds by compiling and asserting the same returned metadata/error shapes.

- [ ] **Step 2: Extract only coherent internal responsibilities**

Split format routing, metadata adaptation or batch-rename rule evaluation only when a unit has one clear input/output contract. Keep access control at `internal` or `private`; do not introduce new `public` declarations.

- [ ] **Step 3: Remove proven dead code**

For each candidate, verify zero references with `rg`, verify it is not a selector/reflection/string lookup, remove it, then build all products. Do not remove compatibility overloads even if internal searches show no caller.

- [ ] **Step 4: Validate core surface**

Run:

```bash
swift build
swift build -c release
swift test --filter ZwzCoreTests
swift test --filter ZwzCLITests
swift test --filter ZwzGUITests
```

Expected: all products compile, 0 failures, no new public declarations, and no changed deterministic archive bytes.

### Task 8: Refactor CLI Internals While Freezing Its Contract

**Files:**
- Modify: `Sources/zwz/CLIArguments.swift`
- Modify: `Sources/zwz/RenameArguments.swift`
- Modify: `Sources/zwz/main.swift`
- Modify tests: `Tests/ZwzCLITests/CLIArgumentsTests.swift`
- Modify tests: `Tests/ZwzCLITests/ZwzCLIRunnerTests.swift`

**Interfaces:**
- Consumes: unchanged `ZwzCore` public APIs and current `CLIDependencies` seam.
- Produces: identical `CLIArguments` parse results, printed lines, secret-input behavior, file replacement behavior and exit codes.

- [ ] **Step 1: Freeze exact command matrix behavior**

Add table-driven parser cases for every command alias, option ordering, help path, invalid combination and batch-rename mode. Add runner cases that separately assert stdout-equivalent output, stderr-equivalent output and concrete thrown errors.

- [ ] **Step 2: Run CLI baseline**

Run:

```bash
swift test --filter CLIArgumentsTests
swift test --filter ZwzCLIRunnerTests
swift run zwz help
```

Expected: tests pass and help output matches the pre-change captured text exactly.

- [ ] **Step 3: Split parser and runner responsibilities**

Extract private/internal command-specific parsing and execution helpers from oversized files. Consolidate duplicated validation and cleanup only when exact error text and evaluation order remain covered. Keep enum cases, initializers and callable test seams unchanged.

- [ ] **Step 4: Validate CLI and real round trips**

Run:

```bash
swift test --filter ZwzCLITests
swift run zwz help
```

Expected: 0 failures; actual ZIP, V2, V3, key and rename workflows retain exact output and results.

### Task 9: Refactor GUI State and Background Work Without Visual Changes

**Files:**
- Modify/split as supported by Task 3 evidence: `Sources/ZwzGUI/ZwzApp.swift`
- Modify/split as supported by Task 3 evidence: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify/split as supported by Task 3 evidence: `Sources/ZwzGUI/IdentityManagerView.swift`
- Modify/split as supported by Task 3 evidence: `Sources/ZwzGUI/IdentityManagerViewModel.swift`
- Modify/split as supported by Task 3 evidence: `Sources/ZwzGUI/WorkspaceContentView.swift`
- Modify/split as supported by Task 3 evidence: remaining files in `Sources/ZwzGUI`
- Modify corresponding tests under `Tests/ZwzGUITests`

**Interfaces:**
- Consumes: unchanged core APIs, localization keys, persistence models and workflow-client seams.
- Produces: identical SwiftUI hierarchy/labels/actions and state transitions with clearer responsibility boundaries and less main-thread work.

- [ ] **Step 1: Lock GUI state and persistence contracts**

Add focused tests for operation generations, stale callback rejection, cancellation, tab persistence, password non-persistence, edit dirty state, public-key recovery retry, batch-rename preview/apply and localization lookup. Compare encoded snapshots exactly where deterministic.

- [ ] **Step 2: Run GUI baseline**

Run:

```bash
swift test --filter ZwzGUITests
swift build --target ZwzGUI
```

Expected: 0 failures and successful GUI build.

- [ ] **Step 3: Extract focused internal units**

Move cohesive private view sections, workflow coordination and pure state transformations into focused files/extensions without changing view order, modifiers, strings, accessibility identifiers or published state semantics. Keep blocking file/crypto work off the main actor and state publication on the main actor.

- [ ] **Step 4: Check concurrency and lifecycle invariants**

Verify every asynchronous callback is guarded by the existing generation/source identity where required; every task cancellation releases resources; identity operations remain serialized where transactional; no password/private key is captured by persistence or logging.

- [ ] **Step 5: Validate GUI regressions**

Run:

```bash
swift test --filter ZwzGUITests
swift build --target ZwzGUI
swift build -c release --target ZwzGUI
```

Expected: 0 failures; both builds exit 0; no changed localization strings, snapshot encodings or workflow ordering.

### Task 10: Complete the Product-File Review and Style Pass

**Files:**
- Modify: only remaining `Sources/**/*.swift` files marked with a supported change in Task 3
- Do not modify: files marked `reviewed-no-change`

**Interfaces:**
- Consumes: all optimized layers.
- Produces: complete one-to-one disposition for every product file and consistent internal style without public or behavior changes.

- [ ] **Step 1: Reconcile the source inventory**

Run:

```bash
rg --files Sources -g '*.swift' | sort
git diff --name-only -- Sources | sort
```

Expected: every source file has either a reviewed diff or a recorded `reviewed-no-change` reason; no file is silently omitted.

- [ ] **Step 2: Apply safe local cleanups**

Within evidence-backed files, simplify duplicated private logic, flatten needlessly complex conditions, correct misleading comments, narrow visibility and improve internal names. Do not reorder code when order affects serialization, UI, CLI output, progress or cancellation.

- [ ] **Step 3: Build after each coherent cleanup group**

Run:

```bash
swift build
```

Expected: exit 0 after each group. If a cleanup cannot be validated by compilation plus an existing focused test, add the focused test or revert the cleanup.

- [ ] **Step 4: Review the complete product diff**

Run:

```bash
git diff --check
git diff --stat -- Sources
git diff -- Sources
```

Expected: no whitespace errors, no accidental dependency or product changes, no public API renames, and no unrelated edits to user-owned files.

### Task 11: Full Automated Verification and Performance Comparison

**Files:**
- Modify: no product files unless verification exposes a regression; any fix returns to the owning task and repeats its focused checks

**Interfaces:**
- Consumes: final candidate implementation.
- Produces: completion evidence for correctness, compatibility, security, performance and memory.

- [ ] **Step 1: Run full Debug verification**

Run:

```bash
swift test
swift build
```

Expected: all existing and added tests pass, only the known desktop RAR fixture may skip, and build exits 0.

- [ ] **Step 2: Run full Release verification**

Run:

```bash
swift build -c release
ZWZ_RUN_PERFORMANCE_TESTS=1 swift test -c release --filter ReleasePerformanceTests
```

Expected: Release build passes. Compare median duration and peak memory to Task 2. No key path may regress beyond repeat-run noise without a documented, user-approved reason.

- [ ] **Step 3: Repeat noisy measurements**

Run every benchmark scenario at least three times after a warm-up. Use the median for wall time and the maximum observed peak memory. Revert changes whose claimed improvement is not repeatable.

- [ ] **Step 4: Verify byte and security compatibility**

Run:

```bash
swift test --filter ZwzV2APITests
swift test --filter ZwzV3CompatibilityTests
swift test --filter ZwzV2SecurityTests
swift test --filter ZwzV3SecurityTests
```

Expected: all deterministic hashes/bytes match; authenticated mutation, wrong-key, traversal, symlink, overflow and cancellation cases retain their exact safe outcomes.

- [ ] **Step 5: Verify final workspace integrity**

Run:

```bash
git status --short
git diff --check
git diff -- Package.swift Package.resolved scripts Packaging
```

Expected: no dependency, package-resolution, script or packaging changes introduced by this optimization; pre-existing user changes remain preserved; no commit or staging action occurred.

### Task 12: Real macOS Manual Acceptance and Final Handoff

**Files:**
- Modify: no files unless a verified defect is found; fixes return to the owning task and repeat automated verification

**Interfaces:**
- Consumes: automated-verification candidate.
- Produces: user-confirmed acceptance result and final optimization report.

- [ ] **Step 1: Build the manual-test app**

Run the project’s existing app packaging path only after confirming it does not alter source or dependency files. Expected: a runnable macOS App with the same bundle identity and resources as the baseline.

- [ ] **Step 2: Give the user a one-item-at-a-time acceptance checklist**

Cover app launch, drag/drop, file association, tabs and shortcuts, archive preview/search, extraction, archive editing, batch rename, password vault, identity management, Touch ID/login-password fallback, public-key missing-key recovery, virtual disk mount/save and cancellation/error cleanup. For each item provide exact action and expected unchanged result.

- [ ] **Step 3: Record user results and resolve failures**

For each failed item, reproduce with the smallest automated test possible, apply the owning task’s test-first fix, and repeat Tasks 11–12. Do not classify an unperformed hardware/UI check as passed.

- [ ] **Step 4: Deliver the final report**

Report: files changed by layer, files reviewed without changes and why, defects fixed, exact test/build results, before/after benchmark medians and peak memory, byte-compatibility evidence, manual-test results, known limitations, and confirmation that no Git commit was created.

# apet M2 实现计划：宠物扩展 + 多源

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 让用户上传自己的宠物照片当桌宠（本地抠图，失败不出丑），同时扫多个 Claude profile，并能配通知模式 + 免打扰。

**Architecture:** 纯逻辑层（PetSelection/CustomPetStore/ForegroundCutter 协议/DataRootDiscovery/DoNotDisturb/HookConstants）全 TDD，系统副作用（Vision/文件 IO/通知）经协议缝隔离；集成/UI 层按 E→C→B→A 串行接入，避免 PreferencesWindow/AppCoordinator 冲突。

**Tech Stack:** Swift 5.9 / SwiftPM 三 target、XCTest、Foundation/AppKit/SwiftUI/Vision/CoreImage。

## Global Constraints

权威设计：`docs/superpowers/specs/2026-06-28-apet-m2-pets-multisource-design.md`。verbatim：

- 零外部依赖（仅系统框架）。纯逻辑不用 `Date()`，`now`/`nowMinOfDay` 注入。
- 系统副作用（Vision/FS/定时器/通知）用协议 + mock 隔离；纯逻辑全 TDD，断言精确。
- 既有 **315 测试零破坏**；既有不变量（唯一 seq 源、ended 不复活、jsonl 不发通知、source 隔离）不动。
- 照片宠物**零网络**。`Package.swift` 保持 `.macOS(.v13)`；Vision 抠图 `@available(macOS 14.0, *)` 守卫，macOS 13 降级。
- **AppConfig 加字段必须写自定义 `init(from:)` + `decodeIfPresent`**（否则旧 config.json 解码失败→ConfigStore 返 defaults→静默丢全部用户设置）。
- **DND `isQuiet`**：`guard enabled` → `if startMin==endMin return false` → 跨午夜公式。
- **抠图失败绝不把白底方块贴桌面**：失败保持当前宠物 + 明确提示 + 重试。
- **PetView 保持纯视图**：PetWindowController 解析 NSImage，PetView 收 `resolvedImage: NSImage?`。
- 默认：notifyMode=attentionOnly、dndEnabled=false、dndStartMin/EndMin=0、selectedPet=shiba。
- 分支 `feature/m2-pets-multisource`；push SSH；身份 clsaa；中文 commit。
- 安装账本（D）**不在本期**（推 M3）。

---

## File Structure

**新建**：
- `Sources/AppShellKit/FileOps.swift` — 文件操作协议 + 真实实现（注入式 FS 缝）。
- `Sources/AgentPetCore/Model/PetKind.swift` — PetKind + PetSelection.parse（纯逻辑）。
- `Sources/AppShellKit/CustomPetStore.swift` — 自定义宠物存储（纯逻辑 + FileOps）。
- `Sources/AppShellKit/ForegroundCutter.swift` — ForegroundCutter 协议 + CutoutError + UnavailableForegroundCutter；`VisionForegroundCutter.swift`（@available 14，Vision 实现）。
- `Sources/AppShellKit/DataRootDiscovery.swift` — 多 root 发现（纯逻辑 + FileOps）。
- `Sources/AgentPetCore/Notify/DoNotDisturb.swift` — DND 纯逻辑。
- `Sources/AppShellKit/HookConstants.swift` — 共享 hook marker 常量。
- `Sources/apet/PetUploadController.swift` — 上传/抠图动线（UI 胶水）。
- 测试：对应 `*Tests.swift`。

**修改**：`Sources/AppShellKit/AppConfig.swift`（dnd 字段 + 自定义 Codable）、`Sources/apet/NotificationService.swift`（DND gate + @preconcurrency）、`Sources/apet/AppCoordinator.swift`（多 watcher + discovery + hookMarker + PetSelection）、`Sources/apet/PetWindowController.swift`（CustomPetStore + applyPet(PetKind)）、`Sources/apet/PetView.swift`（resolvedImage + 呼吸动画）、`Sources/apet/PetAssetLoader.swift`（image(selection:)）、`Sources/apet/PreferencesWindow.swift`（宠物上传段 + 通知/DND 段 + 数据根段 + 健康异步 + hookMarker）。

执行顺序：纯逻辑 T1–T6（可并行）→ 集成 E(T7)→C(T8)→B(T9)→A(T10/T11) → 收尾 T12。

---

## 纯逻辑层（T1–T6，可并行多子 Agent）

### Task 1: PetKind + PetSelection.parse（纯逻辑 TDD）

**Files:** Create `Sources/AgentPetCore/Model/PetKind.swift`; Test `Tests/AgentPetCoreTests/PetSelectionTests.swift`

**Interfaces:** Produces `public enum PetKind: Equatable { case builtin(String); case custom(id: String) }`；`public enum PetSelection { static func parse(_ raw: String) -> PetKind }`

- [ ] **Step 1: 失败测试**

```swift
import XCTest
@testable import AgentPetCore
final class PetSelectionTests: XCTestCase {
    func test_builtin_shiba() { XCTAssertEqual(PetSelection.parse("shiba"), .builtin("shiba")) }
    func test_builtin_bichon() { XCTAssertEqual(PetSelection.parse("bichon"), .builtin("bichon")) }
    func test_custom_withId() { XCTAssertEqual(PetSelection.parse("custom:abc123"), .custom(id: "abc123")) }
    func test_custom_emptyId_fallsBackToShiba() { XCTAssertEqual(PetSelection.parse("custom:"), .builtin("shiba")) }
    func test_empty_fallsBackToShiba() { XCTAssertEqual(PetSelection.parse(""), .builtin("shiba")) }
    func test_unknown_fallsBackToShiba() { XCTAssertEqual(PetSelection.parse("dragon"), .builtin("shiba")) }
}
```

- [ ] **Step 2: 跑失败** — `swift test --filter PetSelectionTests`
- [ ] **Step 3: 实现**

```swift
public enum PetKind: Equatable {
    case builtin(String)
    case custom(id: String)
}
public enum PetSelection {
    public static func parse(_ raw: String) -> PetKind {
        if raw == "shiba" || raw == "bichon" { return .builtin(raw) }
        if raw.hasPrefix("custom:") {
            let id = String(raw.dropFirst("custom:".count))
            return id.isEmpty ? .builtin("shiba") : .custom(id: id)
        }
        return .builtin("shiba")
    }
}
```

- [ ] **Step 4: 跑通** — `swift test --filter PetSelectionTests`
- [ ] **Step 5: 提交** `git add -A && git commit -m "feat: PetKind + PetSelection.parse（含 custom:空id→shiba）（M2-A）"`

### Task 2: FileOps 协议 + CustomPetStore（纯逻辑 TDD）

**Files:** Create `Sources/AppShellKit/FileOps.swift`、`Sources/AppShellKit/CustomPetStore.swift`; Test `Tests/AppShellKitTests/CustomPetStoreTests.swift`

**Interfaces:**
```swift
public protocol FileOps {
    func fileExists(_ path: String) -> Bool
    func createDir(_ path: String) throws
    func copyItem(from: String, to: String) throws
    func removeItem(_ path: String) throws
    func contentsOfDir(_ path: String) -> [String]   // basenames; 不存在→[]
}
public struct RealFileOps: FileOps { public init() }  // FileManager 实现
public struct CustomPetStore {
    public init(rootDir: String, fileOps: FileOps, idProvider: @escaping () -> String)
    public func importPhoto(srcPath: String) throws -> String   // 拷到 <rootDir>/<id>/original.png，返回 id
    public func imagePath(id: String) -> String?                // 优先 cutout.png 否则 original.png；空id→nil
    public func cutoutPath(id: String) -> String                // <rootDir>/<id>/cutout.png（供 cutter 写）
    public func originalPath(id: String) -> String              // <rootDir>/<id>/original.png
    public func list() -> [String]
    public func delete(id: String) throws
}
```
> 注：缩放 ≤512 + 剥 EXIF 属真实图像处理，放 `importPhoto` 的真实实现（用 `CGImageSource`/`CGImageDestination`/`NSImage`）；纯逻辑测**路径决策**（用 mock FileOps，`importPhoto` 的图像处理在 RealFileOps 路径手动验证，store 测试聚焦 imagePath 优先级/list/delete/id 生成）。

- [ ] **Step 1: 失败测试**（mock FileOps 记录调用 + 受控存在性）

```swift
import XCTest
@testable import AppShellKit
final class CustomPetStoreTests: XCTestCase {
    final class MockFileOps: FileOps {
        var existing = Set<String>()
        var dirs = [String: [String]]()
        func fileExists(_ p: String) -> Bool { existing.contains(p) }
        func createDir(_ p: String) throws {}
        func copyItem(from: String, to: String) throws { existing.insert(to) }
        func removeItem(_ p: String) throws { existing.remove(p) }
        func contentsOfDir(_ p: String) -> [String] { dirs[p] ?? [] }
    }
    func test_imagePath_prefersCutout() {
        let fo = MockFileOps()
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "id1" })
        fo.existing.insert("/r/id1/original.png"); fo.existing.insert("/r/id1/cutout.png")
        XCTAssertEqual(store.imagePath(id: "id1"), "/r/id1/cutout.png")
    }
    func test_imagePath_fallsBackToOriginal() {
        let fo = MockFileOps()
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "id1" })
        fo.existing.insert("/r/id1/original.png")
        XCTAssertEqual(store.imagePath(id: "id1"), "/r/id1/original.png")
    }
    func test_imagePath_missing_nil() {
        let store = CustomPetStore(rootDir: "/r", fileOps: MockFileOps(), idProvider: { "id1" })
        XCTAssertNil(store.imagePath(id: "id1"))
    }
    func test_imagePath_emptyId_nil() {
        let store = CustomPetStore(rootDir: "/r", fileOps: MockFileOps(), idProvider: { "x" })
        XCTAssertNil(store.imagePath(id: ""))
    }
    func test_list_returnsSubdirs() {
        let fo = MockFileOps(); fo.dirs["/r"] = ["a", "b"]
        let store = CustomPetStore(rootDir: "/r", fileOps: fo, idProvider: { "x" })
        XCTAssertEqual(store.list().sorted(), ["a", "b"])
    }
}
```

- [ ] **Step 2–4:** 跑失败 → 实现 `FileOps`/`RealFileOps`（FileManager；`importPhoto` 真实实现做缩放 ≤512 长边 + `CGImageDestination` 重编码剥 `kCGImagePropertyGPSDictionary`/`kCGImagePropertyExifDictionary` + 写 original.png）+ `CustomPetStore`（imagePath 优先 cutout、空 id→nil、list/delete/path 拼接）→ 跑通。
- [ ] **Step 5:** 提交 `feat: FileOps协议+CustomPetStore(imagePath优先cutout/缩放剥EXIF)（M2-A,安全MIN-1/架构N-4/用户N-11）`

### Task 3: ForegroundCutter 协议 + CutoutError + 降级决策（纯逻辑 TDD）

**Files:** Create `Sources/AppShellKit/ForegroundCutter.swift`; Test `Tests/AppShellKitTests/ForegroundCutterTests.swift`

**Interfaces:**
```swift
public enum CutoutError: Error, Equatable {
    case platformUnsupported, noForegroundDetected
    case inferenceFailure(String), outputWriteFailed(String)
}
public protocol ForegroundCutter { func cutout(srcPath: String, dstPath: String) async throws }
public struct UnavailableForegroundCutter: ForegroundCutter {  // macOS 13 / 注入降级
    public init()
    public func cutout(srcPath: String, dstPath: String) async throws { throw CutoutError.platformUnsupported }
}
// 抠图结果决策（纯函数，可测）：成功→设为宠物；失败→保持当前+提示文案
public enum CutoutOutcome: Equatable { case setAsPet(cutoutPath: String); case keepCurrent(message: String) }
public enum CutoutDecision {
    public static func decide(result: Result<Void, CutoutError>, cutoutPath: String) -> CutoutOutcome
}
```

- [ ] **Step 1: 失败测试**（决策纯函数 + UnavailableCutter 抛错）

```swift
import XCTest
@testable import AppShellKit
final class ForegroundCutterTests: XCTestCase {
    func test_success_setAsPet() {
        XCTAssertEqual(CutoutDecision.decide(result: .success(()), cutoutPath: "/c.png"),
                       .setAsPet(cutoutPath: "/c.png"))
    }
    func test_noForeground_keepCurrent() {
        XCTAssertEqual(CutoutDecision.decide(result: .failure(.noForegroundDetected), cutoutPath: "/c.png"),
                       .keepCurrent(message: "未识别到宠物主体，请换张主体清晰的照片"))
    }
    func test_writeFailed_keepCurrent_diskMsg() {
        XCTAssertEqual(CutoutDecision.decide(result: .failure(.outputWriteFailed("x")), cutoutPath: "/c.png"),
                       .keepCurrent(message: "存储空间不足，抠图未完成"))
    }
    func test_platformUnsupported_keepCurrent() {
        XCTAssertEqual(CutoutDecision.decide(result: .failure(.platformUnsupported), cutoutPath: "/c.png"),
                       .keepCurrent(message: "抠图需 macOS 14 及以上，可直接用原图"))
    }
    func test_unavailableCutter_throws() async {
        do { try await UnavailableForegroundCutter().cutout(srcPath: "/a", dstPath: "/b"); XCTFail() }
        catch { XCTAssertEqual(error as? CutoutError, .platformUnsupported) }
    }
}
```

- [ ] **Step 2–4:** 跑失败 → 实现 CutoutError/协议/UnavailableForegroundCutter/CutoutDecision.decide（按上面文案映射，inferenceFailure→"抠图未成功，可用原图"）→ 跑通。
- [ ] **Step 5:** 提交 `feat: ForegroundCutter协议+CutoutError+降级决策(失败保持当前)（M2-A,安全MIN-2,产品B-1）`

### Task 4: DataRootDiscovery（纯逻辑 TDD）

**Files:** Create `Sources/AppShellKit/DataRootDiscovery.swift`; Test `Tests/AppShellKitTests/DataRootDiscoveryTests.swift`

**Interfaces:**
```swift
public struct DiscoveryResult: Equatable { public let roots: [DataRoot]; public let newlyDiscovered: [DataRoot] }
public enum DataRootDiscovery {
    // home/existing 的 path 必须是展开绝对路径；只纳入含 projects/ 的 profile 子目录；上限 maxAutoRoots
    public static func discover(home: String, existing: [DataRoot], excluded: [String],
                                fileOps: FileOps, maxAutoRoots: Int = 16) -> DiscoveryResult
}
```
规则：候选 = `<home>/.claude`（若存在）+ `<home>/.claude-profiles/<x>`（每个含 `projects/` 子目录的）；去重（按展开 path，含已在 existing 的不重复）；排除 excluded；截断到 maxAutoRoots；`newlyDiscovered` = 最终 roots 中不在 existing 的。

- [ ] **Step 1: 失败测试**

```swift
import XCTest
@testable import AppShellKit
final class DataRootDiscoveryTests: XCTestCase {
    final class MockFileOps: FileOps {
        var existing = Set<String>(); var dirs = [String:[String]]()
        func fileExists(_ p: String) -> Bool { existing.contains(p) }
        func createDir(_ p: String) throws {}; func copyItem(from: String, to: String) throws {}
        func removeItem(_ p: String) throws {}; func contentsOfDir(_ p: String) -> [String] { dirs[p] ?? [] }
    }
    private func dr(_ p: String) -> DataRoot { DataRoot(path: p, agent: "claude-code") }
    func test_discovers_claude_and_profilesWithProjects() {
        let fo = MockFileOps()
        fo.existing.insert("/h/.claude")
        fo.dirs["/h/.claude-profiles"] = ["work", "junk"]
        fo.existing.insert("/h/.claude-profiles/work/projects")   // work 含 projects/ → 纳入
        // junk 无 projects/ → 不纳入
        let r = DataRootDiscovery.discover(home: "/h", existing: [], excluded: [], fileOps: fo)
        XCTAssertEqual(r.roots.map(\.path).sorted(), ["/h/.claude", "/h/.claude-profiles/work"])
        XCTAssertEqual(r.newlyDiscovered.map(\.path).sorted(), ["/h/.claude", "/h/.claude-profiles/work"])
    }
    func test_dedups_existing() {
        let fo = MockFileOps(); fo.existing.insert("/h/.claude")
        let r = DataRootDiscovery.discover(home: "/h", existing: [dr("/h/.claude")], excluded: [], fileOps: fo)
        XCTAssertEqual(r.roots.map(\.path), ["/h/.claude"])
        XCTAssertTrue(r.newlyDiscovered.isEmpty)   // 已在 existing → 非新发现
    }
    func test_excluded_skipped() {
        let fo = MockFileOps()
        fo.dirs["/h/.claude-profiles"] = ["work"]; fo.existing.insert("/h/.claude-profiles/work/projects")
        let r = DataRootDiscovery.discover(home: "/h", existing: [], excluded: ["/h/.claude-profiles/work"], fileOps: fo)
        XCTAssertTrue(r.roots.isEmpty)
    }
    func test_caps_at_maxAutoRoots() {
        let fo = MockFileOps()
        let names = (0..<20).map { "p\($0)" }
        fo.dirs["/h/.claude-profiles"] = names
        for n in names { fo.existing.insert("/h/.claude-profiles/\(n)/projects") }
        let r = DataRootDiscovery.discover(home: "/h", existing: [], excluded: [], fileOps: fo, maxAutoRoots: 16)
        XCTAssertEqual(r.roots.count, 16)
    }
}
```

- [ ] **Step 2–4:** 跑失败 → 实现 discover（fileExists 判 `<home>/.claude`、`contentsOfDir(<home>/.claude-profiles)` 过滤含 `<dir>/projects` 的、按 path 去重 existing、排除 excluded、截断 maxAutoRoots、算 newlyDiscovered）→ 跑通。
- [ ] **Step 5:** 提交 `feat: DataRootDiscovery(验证projects/+去重+上限+newlyDiscovered)（M2-B,架构M-3/用户M-6）`

### Task 5: DoNotDisturb（纯逻辑 TDD）

**Files:** Create `Sources/AgentPetCore/Notify/DoNotDisturb.swift`; Test `Tests/AgentPetCoreTests/DoNotDisturbTests.swift`

**Interfaces:** `public struct DNDWindow: Equatable { public var enabled: Bool; public var startMin: Int; public var endMin: Int; public init(...) }`；`public func isQuiet(nowMinOfDay: Int) -> Bool`

- [ ] **Step 1: 失败测试**

```swift
import XCTest
@testable import AgentPetCore
final class DoNotDisturbTests: XCTestCase {
    func test_disabled_neverQuiet() {
        XCTAssertFalse(DNDWindow(enabled: false, startMin: 100, endMin: 200).isQuiet(nowMinOfDay: 150))
    }
    func test_startEqualsEnd_neverQuiet() {   // 防 tautology（架构 M-5/用户 M-5）
        XCTAssertFalse(DNDWindow(enabled: true, startMin: 0, endMin: 0).isQuiet(nowMinOfDay: 0))
        XCTAssertFalse(DNDWindow(enabled: true, startMin: 480, endMin: 480).isQuiet(nowMinOfDay: 480))
    }
    func test_sameDayWindow() {   // 09:00-18:00 = 540-1080
        let w = DNDWindow(enabled: true, startMin: 540, endMin: 1080)
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 600))
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 500))
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 540))    // 边界 now==start → 静
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 1080))  // 边界 now==end → 不静
    }
    func test_crossMidnight() {   // 23:00-07:00 = 1380-420
        let w = DNDWindow(enabled: true, startMin: 1380, endMin: 420)
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 1400))   // 23:20
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 60))     // 01:00
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 720))   // 12:00
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 1380))   // now==start
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 420))   // now==end
    }
}
```

- [ ] **Step 2–4:** 跑失败 → 实现（按 spec §5：guard enabled → startMin==endMin return false → `start<end ? (now>=start && now<end) : (now>=start || now<end)`）→ 跑通。
- [ ] **Step 5:** 提交 `feat: DoNotDisturb.isQuiet(跨午夜+start==end防永久静音)（M2-C,架构M-5）`

### Task 6: HookConstants + AppConfig dnd 字段 + 自定义 Codable（纯逻辑 TDD）

**Files:** Create `Sources/AppShellKit/HookConstants.swift`; Modify `Sources/AppShellKit/AppConfig.swift`; Test `Tests/AppShellKitTests/AppConfigTests.swift`（追加）、`Tests/AppShellKitTests/HookConstantsTests.swift`

**Interfaces:** `public enum HookConstants { public static let marker = "apet-1" }`；AppConfig 加 `dndEnabled: Bool`、`dndStartMin: Int`、`dndEndMin: Int`（默认 false/0/0）**及 `excludedRoots: [String]`（默认 `[]`，供 B 子项移除自动发现的 profile 用）**，**自定义 `init(from:)` 对这四个新字段 decodeIfPresent**（一次写好，T9 不再动解码）。

- [ ] **Step 1: 失败测试（关键：向后兼容解码守护架构 B-1）**

```swift
// HookConstantsTests
func test_marker_value() { XCTAssertEqual(HookConstants.marker, "apet-1") }

// AppConfigTests 追加
func test_decode_oldJson_withoutDndFields_keepsOtherSettings_andDefaultsDnd() throws {
    // 旧 config.json（无 dnd 三字段，但有用户自定义 selectedPet/notifyMode）
    let json = #"""
    {"dataRoots":[{"path":"/x/.claude","agent":"claude-code"}],"displayMode":"pet",
     "notifyMode":"everyStop","staleAfterSec":600,"endedAfterSec":14400,
     "waitingEndedAfterSec":28800,"selectedPet":"bichon"}
    """#
    let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    XCTAssertEqual(cfg.selectedPet, "bichon")      // 用户设置不丢
    XCTAssertEqual(cfg.notifyMode, "everyStop")
    XCTAssertEqual(cfg.dndEnabled, false)          // 新字段取默认
    XCTAssertEqual(cfg.dndStartMin, 0)
    XCTAssertEqual(cfg.dndEndMin, 0)
}
func test_roundTrip_withDnd() throws {
    var c = AppConfig.defaults; c.dndEnabled = true; c.dndStartMin = 1380; c.dndEndMin = 420
    let data = try JSONEncoder().encode(c)
    XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), c)
}
```

- [ ] **Step 2: 跑失败**（旧 json 测试会因 keyNotFound 抛错失败）— `swift test --filter AppConfigTests`
- [ ] **Step 3: 实现** — AppConfig 加三字段（init 加带默认值参数）；写自定义 `init(from decoder:)`：必需字段 `decode`，**dnd 三字段 `decodeIfPresent(...) ?? 默认`**；`defaults` 加三字段默认。HookConstants 新建。

```swift
// AppConfig 加字段
public var dndEnabled: Bool
public var dndStartMin: Int
public var dndEndMin: Int
// init 末位加： dndEnabled: Bool = false, dndStartMin: Int = 0, dndEndMin: Int = 0
// 自定义解码：
enum CodingKeys: String, CodingKey { case dataRoots, displayMode, notifyMode, staleAfterSec, endedAfterSec, waitingEndedAfterSec, selectedPet, dndEnabled, dndStartMin, dndEndMin }
public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    dataRoots = try c.decode([DataRoot].self, forKey: .dataRoots)
    displayMode = try c.decode(String.self, forKey: .displayMode)
    notifyMode = try c.decode(String.self, forKey: .notifyMode)
    staleAfterSec = try c.decode(Double.self, forKey: .staleAfterSec)
    endedAfterSec = try c.decode(Double.self, forKey: .endedAfterSec)
    waitingEndedAfterSec = try c.decode(Double.self, forKey: .waitingEndedAfterSec)
    selectedPet = try c.decode(String.self, forKey: .selectedPet)
    dndEnabled = try c.decodeIfPresent(Bool.self, forKey: .dndEnabled) ?? false
    dndStartMin = try c.decodeIfPresent(Int.self, forKey: .dndStartMin) ?? 0
    dndEndMin = try c.decodeIfPresent(Int.self, forKey: .dndEndMin) ?? 0
    excludedRoots = try c.decodeIfPresent([String].self, forKey: .excludedRoots) ?? []
}
// CodingKeys 同时加 .excludedRoots；init/defaults 加 excludedRoots: [String] = []
```

- [ ] **Step 4: 跑通 + 全量回归** — `swift test`（既有 AppConfigTests 不破）
- [ ] **Step 5:** 提交 `feat: AppConfig dnd字段+自定义Codable向后兼容(防丢配置)+HookConstants（M2-C/E,架构B-1/N-2）`

---

## 集成/UI 层（T7–T11，串行 E→C→B→A）

### Task 7: (E) hookMarker 常量化 + 健康面板异步 IO + Sendable

**Files:** Modify `Sources/apet/AppCoordinator.swift`、`Sources/apet/PreferencesWindow.swift`、`Sources/apet/NotificationService.swift`

- [ ] **Step 1:** 删 `AppCoordinator.hookMarker` 静态常量，其引用改 `HookConstants.marker`；`PreferencesView.hookMarker` 字面量改 `HookConstants.marker`（import AppShellKit 已有）。
- [ ] **Step 2:** `PreferencesView.refreshHealthStatus` 的同步文件枚举包进 `Task.detached(priority: .utility) { let snapshot = …; await MainActor.run { self.health = snapshot } }`（避免主线程阻塞）。
- [ ] **Step 3:** `NotificationService.swift` 顶部 `import UserNotifications` 改 `@preconcurrency import UserNotifications`（消除 Sendable 告警）。
- [ ] **Step 4:** `swift build` 通过 + `swift test` 全量绿（315）。
- [ ] **Step 5:** 提交 `refactor: hookMarker常量化+健康面板异步IO+@preconcurrency（M2-E,架构N-2/产品N-3）`

### Task 8: (C) NotificationService DND gate + 首选项通知/DND UI

**Files:** Modify `Sources/apet/NotificationService.swift`、`Sources/apet/AppCoordinator.swift`（传 DNDWindow）、`Sources/apet/PreferencesWindow.swift`（通知段）; Test `Tests/AppShellKitTests/NotificationDNDGateTests.swift`（若可抽纯逻辑）

- [ ] **Step 1:** `NotificationService.consider` 增加 DND 前置：注入 `dndProvider: () -> DNDWindow`（从 config）；在决定投递前，`let nowMin = Calendar.current.component(.hour,...) * 60 + minute`（本地时间，service 边界）；`if dndProvider().isQuiet(nowMinOfDay: nowMin) { return }`（不投递 OS 通知，事件已更新面板）。**抽一个纯函数** `static func shouldSuppress(dnd: DNDWindow, nowMinOfDay: Int) -> Bool { dnd.isQuiet(nowMinOfDay:) }` 便于单测。
- [ ] **Step 2:** 测试 `shouldSuppress`（DND 安静期 true、非安静期 false、disabled false）——精确断言。
- [ ] **Step 3:** AppCoordinator 装配 NotificationService 时注入 `dndProvider: { [weak self] in DNDWindow(enabled: self?.config.dndEnabled ?? false, startMin: …, endMin: …) }`；config 变更（applyConfig）时生效。
- [ ] **Step 4:** PreferencesWindow 通知区块加：notifyMode Picker（attentionOnly/everyStop，绑 config）；DND 开关 + 预设 Picker（深夜 1380/420、工作 540/1080、自定义→时分 Picker）；跨午夜动态说明文本（startMin>endMin 显示"每天 HH:mm 至次日 HH:mm 静音"）。保存写 config。
- [ ] **Step 5:** `swift build` + `swift test` 绿 → 提交 `feat: 通知模式Picker+免打扰预设(DND gate)（M2-C,产品M-4/用户N-10）`

### Task 9: (B) AppCoordinator 多 watcher + discovery + 知情同意 + 面板 profileTag

**Files:** Modify `Sources/apet/AppCoordinator.swift`、`Sources/apet/PreferencesWindow.swift`（数据根段）、`Sources/apet/MenuBarController.swift`（行 profileTag 已有，确认 root>1 渲染）

- [ ] **Step 1:** `jsonlWatcher: JSONLDirectoryWatcher?` → `jsonlWatchers: [JSONLDirectoryWatcher]`；`start()` 改：`let disc = DataRootDiscovery.discover(home: 展开home, existing: config.dataRoots, excluded: config.excludedRoots, fileOps: RealFileOps())`；对 `disc.roots` 每个建 watcher（projectsDir=`<root>/projects`、parse root=该 root、eventId 前缀加 rootLabel）；持有进数组。
- [ ] **Step 2:** `stop()`：`jsonlWatchers.forEach { $0.stop() }; jsonlWatchers.removeAll()`（防 ARC 泄漏）。
- [ ] **Step 3:** 知情同意：`disc.newlyDiscovered` 非空 → 一次性提示（复用 NotificationService 发一条本地通知或健康面板横幅）"发现并加入 N 个 Claude profile，仅读会话状态，可在首选项移除"；把 newlyDiscovered 写入 config.dataRoots 持久化。
- [ ] **Step 4:** AppConfig 加 `excludedRoots: [String]`（同 Task 6 模式：decodeIfPresent ?? []）；PreferencesWindow 数据根列表对自动发现项标「自动发现」+ 移除按钮（移除→加入 excludedRoots）。
- [ ] **Step 5:** MenuBarController/SessionPanel：确认 `SessionRowModel.profileTag` 在 root 数>1 时渲染（已有 profileTag 字段；若未渲染则加 badge）。
- [ ] **Step 6:** `swift build` + `swift test` 绿（注意 AppConfig 加 excludedRoots 需更新 Task6 的自定义解码 + 测试）→ 提交 `feat: 多root并行watcher+发现知情同意+excludedRoots（M2-B,三重收敛同意/架构N-1/N-5）`

### Task 10: (A) PetAssetLoader(selection) + PetView resolvedImage + 呼吸动画 + applyPet 迁移

**Files:** Modify `Sources/apet/PetAssetLoader.swift`、`Sources/apet/PetView.swift`、`Sources/apet/PetWindowController.swift`、`Sources/apet/AppCoordinator.swift`

- [ ] **Step 1:** `PetAssetLoader.image(selection: PetKind, assetState: String, customStore: CustomPetStore?) -> NSImage`：`.builtin(name)` 走原 PNG；`.custom(id)` 从 `customStore?.imagePath(id)` 加载 NSImage，缺失/nil → SF Symbol 兜底。保留旧 `image(pet:assetState:)` 内部委托或删（看调用点）。
- [ ] **Step 2:** `PetView`：`pet: String` 入参 → `resolvedImage: NSImage?`；body 用 `resolvedImage ?? SF Symbol`；移除 body 内 `PetAssetLoader.image` 调用；加呼吸动画 `.scaleEffect(breathing ? 1.03 : 1.0).animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: breathing)` + `.onAppear { breathing = true }`；`.clipShape(Circle())`（custom 时）。
- [ ] **Step 3:** `PetWindowController`：持有 `customStore: CustomPetStore`、`currentSelection: PetKind`；`applyPet(_ selection: PetKind)`（替换 `applyPet(_ pet: String)`）；`update()/applyPet()` 内 `let img = PetAssetLoader.image(selection: currentSelection, assetState:, customStore: customStore)` 传 PetView。
- [ ] **Step 4:** `AppCoordinator`：`pw.applyPet(newConfig.selectedPet)` → `pw.applyPet(PetSelection.parse(newConfig.selectedPet))`；构造 PetWindowController 时注入 customStore；`pet:` 初值用 `PetSelection.parse(config.selectedPet)`。删除旧 String 重载。
- [ ] **Step 5:** `swift build`（确认无旧 applyPet(String) 残留）+ `swift test` 绿 → 提交 `feat: 照片宠物渲染(PetView纯resolvedImage)+呼吸动画+applyPet(PetKind)迁移（M2-A,架构M-1/M-2/产品M-1）`

### Task 11: (A) VisionForegroundCutter + 上传动线 UI + 失败不出丑

**Files:** Create `Sources/AppShellKit/VisionForegroundCutter.swift`、`Sources/apet/PetUploadController.swift`; Modify `Sources/apet/PreferencesWindow.swift`（宠物段）

- [ ] **Step 1:** `VisionForegroundCutter`（`@available(macOS 14.0,*)`）按 spec §3 五步管道实现（CGImageSource 取 EXIF orientation → VNImageRequestHandler.perform → guard allInstances 非空否则 throw .noForegroundDetected → generateMaskedImage → CVPixelBuffer→CIImage→CGImage→NSBitmapImageRep→PNG，nil→throw .outputWriteFailed）。
- [ ] **Step 2:** `PetUploadController`（@MainActor）：`upload()` → NSOpenPanel(png/jpg) → **completionHandler 内同步** `store.importPhoto(srcPath)` 得 id → 弹"一键抠图？"对话 → 选抠图：`Task { let r = await (cutterFactory()).cutoutResult(...); let outcome = CutoutDecision.decide(...); switch outcome { case .setAsPet: 设 config.selectedPet="custom:id" + applyPet; case .keepCurrent(msg): NSAlert 提示 msg，不改宠物 } }`；选原图：直接设 custom:id（原图圆形）。`cutterFactory`：macOS 14+ 返回 VisionForegroundCutter，否则 UnavailableForegroundCutter。
- [ ] **Step 3:** PreferencesWindow 宠物区块：内置柴犬/比熊 + 「上传照片」按钮（触发 PetUploadController）；自定义宠物条目显示「✓已抠图/⚠用原图」+「重新抠图」按钮（重跑抠图，失败保持当前）。
- [ ] **Step 4:** `swift build` + `swift test` 绿；**手动 E2E**：上传一张照片 → 抠图成功 → 桌宠变照片（圆形+呼吸）；抠图失败 → 不变宠物 + 提示。
- [ ] **Step 5:** 提交 `feat: VisionForegroundCutter(@available14,五步管道)+上传动线+失败不出丑+重试（M2-A,安全BLK-1/BLK-2/MAJ-1/MAJ-3,产品B-1）`

### Task 12: 集成验证 + 文档 + 合并推送

- [ ] **Step 1:** `swift test` 全绿（记录数）。
- [ ] **Step 2:** `bash scripts/package-app.sh && open AgentPet.app`，核对：①上传照片→抠图成功→桌宠照片(圆形+呼吸) ②抠图失败→不变宠物+提示 ③多 profile→提示+面板显 [profile] tag ④通知模式 Picker + DND 预设可设 ⑤旧 config.json 升级不丢设置。
- [ ] **Step 3:** CGWindowList 复核桌宠在屏。
- [ ] **Step 4:** 5 视角子 Agent 终审实现 diff，修至无 blocker。
- [ ] **Step 5:** 更新 CLAUDE.md（照片宠物/多root/DND/HookConstants）、README（M2 能力）。
- [ ] **Step 6:** 合并 + 推送：`git checkout main && git merge --no-ff feature/m2-pets-multisource && GIT_SSH_COMMAND='ssh -o BatchMode=yes …' git push origin main`。
- [ ] **Step 7:** 更新 SDD 账本为完成态。

---

## Self-Review

- **Spec 覆盖**：A=T1(PetSelection)/T2(CustomPetStore)/T3(Cutter)/T10(渲染+动画+迁移)/T11(Vision+UI+失败不出丑)；B=T4(Discovery)/T9(多watcher+同意);C=T5(DND)/T6(AppConfig解码)/T8(通知UI+gate);E=T6(HookConstants)/T7(常量化+异步IO+Sendable)。spec §3-§8 全覆盖；D 已删（非目标）。
- **占位扫描**：无 TBD；UI/Vision 手动验证 + 纯逻辑完整 TDD 代码。
- **类型一致**：PetKind/PetSelection.parse、CutoutError/CutoutOutcome/CutoutDecision、DNDWindow.isQuiet、DiscoveryResult、FileOps、HookConstants.marker 跨任务一致；applyPet(PetKind) 迁移全程一致。
- **blocker 守护**：架构B-1→T6向后兼容解码测试；安全BLK-1/2→T3/T11 @available+async;DND tautology→T5;白底→T3决策+T11 UI;PetView纯→T10。
- **顺序**：T6 先于 T8/T9（AppConfig 解码地基）；T9 再加 excludedRoots 需回更 T6 解码（已在 T9 Step6 标注）。

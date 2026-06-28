# M3-A0 体验热修 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉 4 个日常高频体验缺陷：点宠物可靠弹窗(B2)、看完通知/列表即标已读(B1)、内置宠物透明背景(B3)、桌宠面板可退出 App(A1)。

**Architecture:** 把可决策逻辑全部下沉为 AgentPetCore/AppShellKit 纯函数（apet 无测试 target，留在 apet 的逻辑测不到）；GUI 只做薄胶水消费纯函数结果。每个修复 = 1 个纯逻辑单元(可单测) + 一处 GUI 接线(手测 smoke)。

**Tech Stack:** Swift 5.9 语言模式 / Swift 6.x 工具链；SwiftPM 三 target（AgentPetCore 纯逻辑、AppShellKit 可测胶水、apet GUI）；XCTest；零第三方依赖。

## Global Constraints

- 零外部依赖，只用 Foundation/AppKit/SwiftUI 标准库。
- core 纯逻辑：AgentPetCore **无 GUI、无系统副作用、不调 `Date()`**；当前时间一律 `now: Double` 注入。
- 测试是规范：测试失败改实现、不改测试；断言精确，覆盖正常/边界/异常。
- apet 层只做薄胶水；凡可决策逻辑下沉 AgentPetCore/AppShellKit 纯函数。
- 文件路径镜像测试：`Sources/X/Foo.swift` → `Tests/XTests/FooTest.swift`。
- 提交粒度：一个可独立测试的交付物一个 commit；中文 commit message。
- `swift test` 提交前必须全绿（当前基线 419 测试）。
- 分支：在 `feature/m3-experience` 上开发（已创建），勿在 main。

---

### Task 1: B2 — 宠物点击可靠弹窗（ClickDragClassifier + PopoverShowPlanner）

**Files:**
- Create: `Sources/AgentPetCore/Input/ClickDragClassifier.swift`
- Create: `Sources/AgentPetCore/Input/PopoverShowPlanner.swift`
- Modify: `Sources/apet/PetWindowController.swift`（`DragDetectorView` 用 classifier；`togglePopover` 用 planner 重试）
- Test: `Tests/AgentPetCoreTests/ClickDragClassifierTests.swift`、`Tests/AgentPetCoreTests/PopoverShowPlannerTests.swift`

**Interfaces:**
- Produces:
  - `enum Gesture: Equatable { case click; case drag }`
  - `enum ClickDragClassifier { static func classify(maxAbsDx: CGFloat, maxAbsDy: CGFloat, threshold: CGFloat) -> Gesture }`
  - `enum PostOpenAction: Equatable { case ok; case retry; case giveUp }`
  - `struct PopoverShowPlanner { func planAfterOpen(isShownNow: Bool, attempt: Int, maxAttempts: Int) -> PostOpenAction }`
- Consumes: 无（纯逻辑，CGFloat 来自 CoreGraphics，AgentPetCore 可 `import CoreGraphics`）。

- [ ] **Step 1: 写失败测试（分类器）**

`Tests/AgentPetCoreTests/ClickDragClassifierTests.swift`：
```swift
import XCTest
import CoreGraphics
@testable import AgentPetCore

final class ClickDragClassifierTests: XCTestCase {
    // TC-B2-FUNC-01 静止 → click
    func test_classify_returnsClick_whenNoMovement() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 0, maxAbsDy: 0, threshold: 8), .click)
    }
    // TC-B2-FUNC-02 阈值内微抖 → click（触控板抖动不应误判拖动）
    func test_classify_returnsClick_whenJitterBelowThreshold() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 7, maxAbsDy: 3, threshold: 8), .click)
    }
    // TC-B2-FUNC-03 达到阈值 → drag
    func test_classify_returnsDrag_whenReachesThresholdX() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 8, maxAbsDy: 0, threshold: 8), .drag)
    }
    // TC-B2-PARAM-04 任一轴超阈值即 drag
    func test_classify_returnsDrag_whenYExceedsThreshold() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 1, maxAbsDy: 20, threshold: 8), .drag)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ClickDragClassifierTests`
Expected: 编译失败（`ClickDragClassifier` 未定义）。

- [ ] **Step 3: 实现分类器**

`Sources/AgentPetCore/Input/ClickDragClassifier.swift`：
```swift
import CoreGraphics

/// 点击/拖动判定的纯逻辑。`DragDetectorView` 采集鼠标移动的最大位移后调用本函数，
/// 自身不持有任何 GUI/可变状态，便于单测覆盖抖动/微移/拖动边界。
public enum Gesture: Equatable { case click; case drag }

public enum ClickDragClassifier {
    /// 任一轴的最大绝对位移达到 `threshold` 即判为拖动；否则点击。
    public static func classify(maxAbsDx: CGFloat, maxAbsDy: CGFloat, threshold: CGFloat) -> Gesture {
        (maxAbsDx >= threshold || maxAbsDy >= threshold) ? .drag : .click
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ClickDragClassifierTests`
Expected: 4 passed。

- [ ] **Step 5: 写失败测试（弹窗重试 planner）**

`Tests/AgentPetCoreTests/PopoverShowPlannerTests.swift`：
```swift
import XCTest
@testable import AgentPetCore

final class PopoverShowPlannerTests: XCTestCase {
    let planner = PopoverShowPlanner()
    // TC-B2-FUNC-05 open 后已显示 → ok，不重试（杜绝 double-show）
    func test_planAfterOpen_ok_whenShown() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: true, attempt: 1, maxAttempts: 2), .ok)
    }
    // TC-B2-FUNC-06 open 后未显示且有剩余次数 → retry（修首击被吞）
    func test_planAfterOpen_retry_whenNotShownAndAttemptsLeft() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: false, attempt: 1, maxAttempts: 2), .retry)
    }
    // TC-B2-ERR-07 用尽次数仍未显示 → giveUp，不无限重试
    func test_planAfterOpen_giveUp_whenAttemptsExhausted() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: false, attempt: 2, maxAttempts: 2), .giveUp)
    }
}
```

- [ ] **Step 6: 跑测试确认失败**

Run: `swift test --filter PopoverShowPlannerTests`
Expected: 编译失败（`PopoverShowPlanner` 未定义）。

- [ ] **Step 7: 实现 planner**

`Sources/AgentPetCore/Input/PopoverShowPlanner.swift`：
```swift
/// popover 弹出后的重试决策纯状态机。
/// LSUIElement 背景 App 下 transient popover 锚到刚激活的非 key 窗口偶发吞首击；
/// 弹出后若未显示且仍有重试次数则 retry，已显示则 ok（绝不重复弹），次数耗尽 giveUp。
public enum PostOpenAction: Equatable { case ok; case retry; case giveUp }

public struct PopoverShowPlanner {
    public init() {}
    public func planAfterOpen(isShownNow: Bool, attempt: Int, maxAttempts: Int) -> PostOpenAction {
        if isShownNow { return .ok }
        return attempt < maxAttempts ? .retry : .giveUp
    }
}
```

- [ ] **Step 8: 跑测试确认通过**

Run: `swift test --filter PopoverShowPlannerTests`
Expected: 3 passed。

- [ ] **Step 9: 接线 DragDetectorView 用 classifier**

`Sources/apet/PetWindowController.swift` 中 `DragDetectorView`：用累积的最大位移 + `ClickDragClassifier` 替换 `hasDragged` 布尔累加。改动要点（保持 `onClicked`/`onDragEnded` 回调不变）：
```swift
import AgentPetCore  // 若文件已 import 则忽略
// DragDetectorView 内：
private var maxAbsDx: CGFloat = 0
private var maxAbsDy: CGFloat = 0
private let dragThreshold: CGFloat = 8

override func mouseDown(with event: NSEvent) {
    dragStartLocation = NSEvent.mouseLocation
    windowOriginAtDragStart = window?.frame.origin ?? .zero
    maxAbsDx = 0; maxAbsDy = 0
}
override func mouseDragged(with event: NSEvent) {
    let current = NSEvent.mouseLocation
    let dx = current.x - dragStartLocation.x
    let dy = current.y - dragStartLocation.y
    maxAbsDx = max(maxAbsDx, abs(dx)); maxAbsDy = max(maxAbsDy, abs(dy))
    window?.setFrameOrigin(NSPoint(x: windowOriginAtDragStart.x + dx,
                                   y: windowOriginAtDragStart.y + dy))
}
override func mouseUp(with event: NSEvent) {
    switch ClickDragClassifier.classify(maxAbsDx: maxAbsDx, maxAbsDy: maxAbsDy, threshold: dragThreshold) {
    case .drag:  onDragEnded?()
    case .click: onClicked?()
    }
}
```

- [ ] **Step 10: 接线 togglePopover 用 planner 重试**

`Sources/apet/PetWindowController.swift` `togglePopover()` 的弹出分支：先 key 窗口，`popover.show` 后在下一 runloop 校验 `popover.isShown`，按 `PopoverShowPlanner` 决定是否再 show 一次（最多 2 次）。要点（不得在已 shown 时再 show → 杜绝 double-show）：
```swift
private let popoverPlanner = PopoverShowPlanner()
// 在 show(relativeTo:...) 之后：
func attemptShow(_ attempt: Int) {
    p.show(relativeTo: anchor, of: contentView, preferredEdge: .maxY)
    DispatchQueue.main.async { [weak self] in
        guard let self, let p = self.popover else { return }
        switch self.popoverPlanner.planAfterOpen(isShownNow: p.isShown, attempt: attempt, maxAttempts: 2) {
        case .ok, .giveUp: break
        case .retry:       attemptShow(attempt + 1)
        }
    }
}
attemptShow(1)
```

- [ ] **Step 11: 全量编译 + 测试 + 手测**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: Build complete；测试数 = 419 + 7（新增）= 426，全绿。
手测（实现期）：`bash scripts/package-app.sh && open AgentPet.app`，连续点宠物 20 次必弹、不出现弹后即消失/重复弹。**负向验收：不得 double-show。**（分类器/planner 单测 ≠ B2 手测验收，二者都要过。）

- [ ] **Step 12: 提交**

```bash
git add Sources/AgentPetCore/Input/ Sources/apet/PetWindowController.swift Tests/AgentPetCoreTests/ClickDragClassifierTests.swift Tests/AgentPetCoreTests/PopoverShowPlannerTests.swift
git commit -m "fix(B2): 宠物点击可靠弹窗——ClickDragClassifier + PopoverShowPlanner 纯逻辑下沉 + 重试兜底"
```

---

### Task 2: B1 — 看完即标已读（NotificationClickResolver + acknowledgeAll + 接线）

**Files:**
- Create: `Sources/AppShellKit/NotificationClickResolver.swift`
- Modify: `Sources/AgentPetCore/Store/SessionStore.swift`（新增 `acknowledgeAll`）
- Modify: `Sources/apet/NotificationService.swift`（didReceive 用 resolver + 调 onAcknowledge）
- Modify: `Sources/apet/AppCoordinator.swift`（注入 onAcknowledge 到 NotificationService；列表点击路径补 ack）
- Modify: `Sources/apet/SessionPanel.swift` + `Sources/apet/MenuBarController.swift` + `Sources/apet/PetWindowController.swift`（面板加"全部已读"按钮）
- Test: `Tests/AppShellKitTests/NotificationClickResolverTests.swift`、`Tests/AgentPetCoreTests/SessionStoreAcknowledgeAllTests.swift`

**Interfaces:**
- Produces:
  - `enum SessionAction: Equatable { case acknowledge(SessionKey); case focus(SessionKey) }`
  - `enum NotificationClickResolver { static func resolve(userInfo: [String: Any]) -> [SessionAction] }`
  - `extension SessionStore { func acknowledgeAll() -> [StoreChange] }`
- Consumes: `SessionKey(agent:root:sessionId:)`（AgentPetCore）；`store.acknowledge(key:) -> [StoreChange]`（既有）。

- [ ] **Step 1: 写失败测试（resolver）**

`Tests/AppShellKitTests/NotificationClickResolverTests.swift`：
```swift
import XCTest
import AgentPetCore
@testable import AppShellKit

final class NotificationClickResolverTests: XCTestCase {
    // TC-B1-FUNC-01 合法 userInfo → 先 acknowledge 再 focus
    func test_resolve_returnsAckThenFocus_whenValid() {
        let info: [String: Any] = ["agent": "claude", "root": "/r", "sessionId": "s1"]
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s1")
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: info), [.acknowledge(key), .focus(key)])
    }
    // TC-B1-ERR-02 缺字段 → 空动作（不崩、不臆造 key）
    func test_resolve_returnsEmpty_whenMissingField() {
        XCTAssertEqual(NotificationClickResolver.resolve(userInfo: ["agent": "claude"]), [])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter NotificationClickResolverTests`
Expected: 编译失败（未定义）。

- [ ] **Step 3: 实现 resolver**

`Sources/AppShellKit/NotificationClickResolver.swift`：
```swift
import Foundation
import AgentPetCore

/// 通知点击的纯决策：从 userInfo 解析 SessionKey，输出"先标已读再聚焦"动作序列。
/// 放 AppShellKit 而非 apet，使其可单测（apet 无测试 target、UNNotificationResponse 不可构造）。
public enum SessionAction: Equatable {
    case acknowledge(SessionKey)
    case focus(SessionKey)
}

public enum NotificationClickResolver {
    public static func resolve(userInfo: [String: Any]) -> [SessionAction] {
        guard let agent = userInfo["agent"] as? String,
              let root = userInfo["root"] as? String,
              let sessionId = userInfo["sessionId"] as? String else { return [] }
        let key = SessionKey(agent: agent, root: root, sessionId: sessionId)
        return [.acknowledge(key), .focus(key)]
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter NotificationClickResolverTests`
Expected: 2 passed。

- [ ] **Step 5: 写失败测试（acknowledgeAll）**

`Tests/AgentPetCoreTests/SessionStoreAcknowledgeAllTests.swift`（参照现有 SessionStore 测试构造 waiting 会话的方式；用 `.stop` 事件经 ingest→apply 造 waiting 态）：
```swift
import XCTest
@testable import AgentPetCore

final class SessionStoreAcknowledgeAllTests: XCTestCase {
    // TC-B1-FUNC-03 全部已读后 doneCount 归零（所有 waiting 置 acknowledged）
    func test_acknowledgeAll_zeroesDoneCount() {
        let store = SessionStore()
        let now = 1000.0
        // 造两个 waiting(.stop) 会话
        for i in 1...2 {
            let ev = AgentEvent(v: 1, eventId: "e\(i)", seq: i, agent: "claude", root: "/r",
                                sessionId: "s\(i)", kind: .stop, ts: now, cwd: nil, title: nil, terminal: nil)
            _ = store.apply(event: ev, now: now)
        }
        XCTAssertEqual(store.summary().doneCount, 2)
        _ = store.acknowledgeAll()
        XCTAssertEqual(store.summary().doneCount, 0)
    }
}
```
> 注：`AgentEvent` 构造参数以现有定义为准，实现者读 `Sources/AgentPetCore/Model/AgentEvent.swift` 对齐字段；造 waiting 的方式参照现有 `SessionStore*Tests`。

- [ ] **Step 6: 跑测试确认失败**

Run: `swift test --filter SessionStoreAcknowledgeAllTests`
Expected: 失败（`acknowledgeAll` 未定义）。

- [ ] **Step 7: 实现 acknowledgeAll**

`Sources/AgentPetCore/Store/SessionStore.swift` 在 `acknowledge(key:)` 附近新增（复用单会话 acknowledge 的逻辑，遍历所有 waiting+未 ack 会话）：
```swift
/// 把所有 waiting 且未确认的会话一并标记已读，聚合广播变更。用于面板"全部已读"。
public func acknowledgeAll() -> [StoreChange] {
    var changes: [StoreChange] = []
    for key in sessions.keys {
        changes.append(contentsOf: acknowledge(key: key))
    }
    return changes
}
```
> 实现者确认 `sessions` 字段名/可见性；若内部容器名不同则对齐。`acknowledge(key:)` 内部已 guard 仅 `.waiting` 生效，故遍历安全。

- [ ] **Step 8: 跑测试确认通过**

Run: `swift test --filter SessionStoreAcknowledgeAllTests`
Expected: passed。

- [ ] **Step 9: 接线通知点击 → resolver + acknowledge**

`Sources/apet/NotificationService.swift`：新增注入闭包 `onAcknowledge: (SessionKey) -> Void`（默认空），`didReceive` 改用 `NotificationClickResolver.resolve(userInfo:)`，对 `.acknowledge` 调 `onAcknowledge`（@MainActor），对 `.focus` 走既有 focus 逻辑。`AppCoordinator` 构造 NotificationService 时注入 `onAcknowledge = { [weak self] key in _ = self?.store?.acknowledge(key: key) }`（store 变更会经既有 changeHandler 刷新面板/桌宠）。

- [ ] **Step 10: 接线列表点击 → 也 ack**

`AppCoordinator` 既有的会话行点击路径（`handleSessionTap`/`ack` 闭包，约 AppCoordinator.swift:222）：在跳转聚焦的同时调用 `store.acknowledge(key:)`（用户更常点列表而非横幅）。确认点击 id→SessionKey 的还原逻辑复用既有 `SessionRowModel.id` ↔ key 映射。

- [ ] **Step 11: 面板加"全部已读"按钮**

`SessionPanel` 增可选回调 `var onAcknowledgeAll: (() -> Void)? = nil`，rows 非空时在列表顶部/底部显示"全部标记已读"按钮（仅当存在未读时可点）。`PanelRootView`(MenuBarController) 与 `PetPanelRootView`(PetWindowController) 注入该回调 → `store.acknowledgeAll()`。

- [ ] **Step 12: 全量编译 + 测试 + 手测**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: 426 + 3 = 429 全绿。
手测：点通知横幅 / 点面板会话行 / 点"全部已读" → 红点即时转黄。

- [ ] **Step 13: 提交**

```bash
git add Sources/AppShellKit/NotificationClickResolver.swift Sources/AgentPetCore/Store/SessionStore.swift Sources/apet/NotificationService.swift Sources/apet/AppCoordinator.swift Sources/apet/SessionPanel.swift Sources/apet/MenuBarController.swift Sources/apet/PetWindowController.swift Tests/AppShellKitTests/NotificationClickResolverTests.swift Tests/AgentPetCoreTests/SessionStoreAcknowledgeAllTests.swift
git commit -m "fix(B1): 看完通知/列表即标已读 + 全部已读——NotificationClickResolver + acknowledgeAll 下沉"
```

---

### Task 3: B3 — 内置宠物透明背景 + 统一圆裁

**Files:**
- Modify(二进制): `Resources/pets/shiba/idle.png`、`Resources/pets/bichon/idle.png`（白底 → 透明）
- Modify: `Sources/apet/PetView.swift`（`petImage` 去掉 `if isCustomPet` 分支，统一 `clipShape(Circle())`）
- Test: `Tests/AppShellKitTests/BuiltinPetAssetTests.swift`（断言透明）

**Interfaces:**
- Consumes: 无新接口。`PetView.isCustomPet` 参数保留（向后兼容调用点）但 `petImage` 不再据它分支。

- [ ] **Step 1: 生成透明 PNG（白底 → alpha，色键）**

内置是 512×512 卡通精灵、白底，用白色色键转透明（比 Vision 实例掩码更适合插画）。在仓库根跑（PIL 本机已装）：
```bash
cd /Users/renguijie/workspace/apet
python3 - <<'PY'
from PIL import Image
for name in ("shiba","bichon"):
    p=f"Resources/pets/{name}/idle.png"
    im=Image.open(p).convert("RGBA")
    px=im.load()
    w,h=im.size
    for y in range(h):
        for x in range(w):
            r,g,b,a=px[x,y]
            # 近白(各通道>=245)判为背景 → 全透明
            if r>=245 and g>=245 and b>=245:
                px[x,y]=(r,g,b,0)
    im.save(p)
    print("done",p,im.mode)
PY
```
> 若精灵主体含大面积纯白会被误抠，实现者目视检查 `open Resources/pets/shiba/idle.png` 预览；必要时调阈值或改用边缘 flood-fill。产物入仓。

- [ ] **Step 2: 写失败测试（断言透明）**

`Tests/AppShellKitTests/BuiltinPetAssetTests.swift`：
```swift
import XCTest
import AppKit

final class BuiltinPetAssetTests: XCTestCase {
    // 仓库根：从本测试文件路径上溯到 apet/
    private func repoPetPath(_ name: String) -> String {
        var url = URL(fileURLWithPath: #filePath) // .../apet/Tests/AppShellKitTests/BuiltinPetAssetTests.swift
        for _ in 0..<3 { url.deleteLastPathComponent() }   // → apet/
        return url.appendingPathComponent("Resources/pets/\(name)/idle.png").path
    }
    private func cgImage(_ path: String) -> CGImage? {
        guard let data = NSData(contentsOfFile: path),
              let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    // TC-B3-FUNC-01 含 alpha 通道
    func test_builtinPets_haveAlphaChannel() {
        for name in ["shiba","bichon"] {
            guard let img = cgImage(repoPetPath(name)) else { return XCTFail("无法读 \(name)") }
            let ai = img.alphaInfo
            XCTAssertFalse(ai == .none || ai == .noneSkipFirst || ai == .noneSkipLast,
                           "\(name) 缺 alpha 通道（仍是不透明方块）")
        }
    }
    // TC-B3-FUNC-02 左上角像素 alpha == 0（背景已透明）
    func test_builtinPets_cornerIsTransparent() {
        for name in ["shiba","bichon"] {
            guard let img = cgImage(repoPetPath(name)),
                  let data = img.dataProvider?.data,
                  let ptr = CFDataGetBytePtr(data) else { return XCTFail("无像素 \(name)") }
            // 默认 RGBA8：第 4 字节是左上角 alpha
            let alpha = ptr[3]
            XCTAssertEqual(alpha, 0, "\(name) 左上角不透明")
        }
    }
}
```
> 实现者：若 CGImage 字节序非预期 RGBA，按实际 `bitmapInfo` 调整角点 alpha 取址；核心断言是"四角透明"。

- [ ] **Step 3: 跑测试确认失败（处理前）**

Run: `swift test --filter BuiltinPetAssetTests`
Expected: 处理前会失败（RGB 无 alpha）。若 Step 1 已先跑则改为先确认失败：可临时 `git stash` 资产验证红→绿。实现者保证先看到红。

- [ ] **Step 4: 统一圆裁（去 isCustomPet 分支）**

`Sources/apet/PetView.swift` `petImage`：
```swift
@ViewBuilder
private var petImage: some View {
    let fallback = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "pet") ?? NSImage()
    let nsImage = resolvedImage ?? fallback
    Image(nsImage: nsImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 96, height: 96)
        .clipShape(Circle())   // 内置已透明，与自定义统一圆裁
}
```

- [ ] **Step 5: 跑测试确认通过 + 全量**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: 全绿（429 + 2 = 431）。手测 `open AgentPet.app`：桌面宠物无白底方块。

- [ ] **Step 6: 提交**

```bash
git add Resources/pets/shiba/idle.png Resources/pets/bichon/idle.png Sources/apet/PetView.swift Tests/AppShellKitTests/BuiltinPetAssetTests.swift
git commit -m "fix(B3): 内置宠物透明背景（白色色键）+ 统一圆裁，消除不透明方块"
```

---

### Task 4: A1 — 桌宠/菜单栏面板加"退出"入口

**Files:**
- Modify: `Sources/apet/PetWindowController.swift`（`PetPanelRootView` 页脚加"退出 apet"）
- Modify: `Sources/apet/MenuBarController.swift`（`PanelRootView` 页脚加"退出 apet"，若尚无）
- Test: 无新单测（纯 GUI 按钮；行为 = `NSApp.terminate(nil)`，手测 smoke）

**Interfaces:**
- Consumes: 既有 `PetPanelRootView`（含 `onOpenPreferences`）、`PanelRootView`。

- [ ] **Step 1: PetPanelRootView 加退出按钮**

`Sources/apet/PetWindowController.swift` `PetPanelRootView.body` 在"首选项…"按钮之后追加：
```swift
Button {
    NSApp.terminate(nil)
} label: {
    Label("退出 apet", systemImage: "power")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
}
.buttonStyle(.plain)
.foregroundStyle(.secondary)
.padding(.horizontal, 10)
.padding(.bottom, 4)
```
并把 `SessionPanelHostController` 的 popover 高度（`p.contentSize` 在 togglePopover 内，约 436/464）各 +34 容纳新按钮。

- [ ] **Step 2: PanelRootView 确认有退出**

`Sources/apet/MenuBarController.swift` `PanelRootView`：若页脚已有"退出"则跳过；若无，按同样样式追加"退出 apet" → `NSApp.terminate(nil)`。

- [ ] **Step 3: 编译 + 测试 + 手测**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: 431 全绿（无新测试，数不变）。手测：点宠物 → 面板底部"退出 apet" → App 退出。

- [ ] **Step 4: 提交**

```bash
git add Sources/apet/PetWindowController.swift Sources/apet/MenuBarController.swift
git commit -m "fix(A1): 桌宠/菜单栏面板加「退出 apet」入口，解状态栏被刘海藏时无法退出"
```

---

## 里程碑收尾（全部任务后）

- [ ] 全量 `swift build && swift test`（期望 ~431 全绿）+ `bash scripts/package-app.sh && open AgentPet.app` headless smoke 不崩。
- [ ] 派 5 视角（架构/产品/AI/用户/测试）子 Agent 对整批 diff 做 whole-branch 评审（并行、只读、不嵌套派生）；Critical/Important 用一个 fix 子 Agent 批量修。
- [ ] 通过后用 superpowers:finishing-a-development-branch 决定合并。

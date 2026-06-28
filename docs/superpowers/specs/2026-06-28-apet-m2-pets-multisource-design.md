# apet M2 设计：宠物扩展 + 多源（v2，已纳入 5 视角面板评审）

> 状态：v2（架构/安全平台/产品/用户/测试 五视角评审已整合，见 §10）
> 日期：2026-06-28
> 前序：`2026-06-27-apet-design.md`（§11 M2）+ `2026-06-28-apet-onboarding-jsonl-menubar-design.md`（M1.5）
> 用户决策：照片宠物 = **本地 Vision 抠图 + 原图直接用**（不做 AI 手绘，零网络零成本）；M2 全量自主推进。

## 1. 范围（v2，砍掉安装账本）

M2「宠物扩展 + 多源」分 4 个**独立子项**（**安装账本推迟到 M3**，与卸载流程一起做——产品评审 M-5：低用户价值、高复杂度，YAGNI）：

| 子项 | 一句话 |
|------|--------|
| **A 照片宠物** | 上传宠物照片 → 桌宠；可选一键抠图（本地 Vision，macOS 14+）；失败不出丑；轻呼吸动画 |
| **B 多 root 并行** | 扫 `~/.claude` + `~/.claude-profiles/*`（**知情同意 + 结构验证 + 上限**） |
| **C 通知模式 + 免打扰** | 「需关注才响」(默认)/「每轮结束都响」可切 + 免打扰预设时段 |
| **E M1.5 技术债** | hookMarker 常量化 / 健康面板异步 IO / Swift6 Sendable(`@preconcurrency`) / applyPet 迁移 |

## 2. 全局约束

- 零外部依赖（Foundation/AppKit/SwiftUI/Vision/CoreImage——均系统框架）。纯逻辑不用 `Date()`，`now` 注入。
- 系统副作用（Vision、文件 IO、定时器）用**协议缝 + mock** 隔离；纯逻辑全 TDD。
- 既有 315 测试零破坏；既有不变量（唯一 seq 源、ended 不复活、jsonl 不发通知、source 隔离）不动。
- 照片宠物**零网络**。
- **平台**：`Package.swift` 保持 `.macOS(.v13)`；Vision 抠图功能用 `@available(macOS 14.0, *)` 守卫，macOS 13 优雅降级（见 §3）。

---

## 3. 子项 A：照片宠物

### 现状 → 改造
- **现状**：`PetView.petImage`（§注释"纯视图"）在 view body 直接调 `PetAssetLoader.image(pet: String, assetState:)` 同步读内置 PNG；`PetWindowController.currentPet: String` + `applyPet(_ pet: String)`；`AppCoordinator.applyConfig`(L277) `pw.applyPet(newConfig.selectedPet)`；`config.selectedPet: String`。
- **改造**：`selectedPet` 取值 `"shiba" | "bichon" | "custom:<id>"`；新增上传/抠图/存储/加载；照片宠物**单图降级**（所有状态共用一张图，靠状态点+角标区分）+ **轻呼吸动画**给静态图生命感（产品 M-1）。

### 组件
- **PetSelection（纯逻辑，AgentPetCore，可测）**：`enum PetKind { case builtin(String); case custom(id: String) }` + `static func parse(_ raw: String) -> PetKind`。规则：`"shiba"/"bichon"` → builtin；`"custom:<非空id>"` → custom(id)；**`"custom:"`（空 id）/ 空串 / 未知 → `.builtin("shiba")`**（用户 M-4）。
- **CustomPetStore（纯逻辑 + 注入式 FS，AppShellKit，可测）**：管理 `~/Library/Application Support/AgentPet/pets-custom/<id>/{original.png, cutout.png?}`。
  - `init(fileOps: FileOps, idProvider: () -> String)`（`idProvider: () -> String` 显式类型——用户 N-11；测试注入固定 id）。
  - `importPhoto(srcPath: String) throws -> String`：① 读图 → **若长边 > 512px 缩放到 512**（架构 N-4，抠图前，省内存/耗时）② **用 `CGImageDestination` 重编码剥除 EXIF/GPS 元数据**（安全 MIN-1）③ 写 `original.png` ④ 返回 id。**必须在 NSOpenPanel completionHandler 内同步调用**（安全 MIN-3，沙盒迁移留口）。
  - `imagePath(id: String) -> String?`：优先 `cutout.png`，否则 `original.png`，都无 → nil。空 id → nil。
  - `setCutout(id:, cutoutPath:)` / `list()` / `delete(id)`。
  - FS 经 `protocol FileOps` 注入，纯逻辑测路径决策。
- **ForegroundCutter（协议，AppShellKit）**：
  ```swift
  enum CutoutError: Error, Equatable {
      case platformUnsupported          // macOS < 14
      case noForegroundDetected         // allInstances 为空
      case inferenceFailure(String)     // Vision 推理出错
      case outputWriteFailed(String)    // 写 PNG 失败/磁盘满
  }
  protocol ForegroundCutter { func cutout(srcPath: String, dstPath: String) async throws }  // async（安全 BLK-2：Vision perform 同步阻塞 300ms-2s，必须离主线程）
  ```
  - **`VisionForegroundCutter`**（`@available(macOS 14.0, *)`，安全 BLK-1/架构 B-2）实现要点（安全 MAJ-1，避免踩坑）：
    1. `CGImageSource` 读 src，取 **EXIF Orientation** 传给 handler（否则抠图区旋转错位）。
    2. `VNImageRequestHandler.perform([VNGenerateForegroundInstanceMaskRequest])`。
    3. `results.first as? VNInstanceMaskObservation`；**`guard !observation.allInstances.isEmpty else { throw .noForegroundDetected }`**（安全 MAJ-3：无主体时 generateMaskedImage 产全透明/黑图，不会 throw）。
    4. `generateMaskedImage(ofInstances: allInstances, from: handler, croppingToInstancesExtent: false)` → `CVPixelBuffer`（带 alpha）。
    5. `CVPixelBuffer → CIImage → CGImage`（`CIContext`）→ `NSBitmapImageRep(cgImage:)` → `.representation(using: .png)` → `Data`；**任一步 nil → throw .outputWriteFailed**（保 alpha 不丢）。
  - macOS 13：工厂返回 **`UnavailableForegroundCutter`**（`cutout` 直接 `throw .platformUnsupported`）；UI 灰化"抠图"按钮或提示"需 macOS 14+"。
  - 纯逻辑/上层只依赖协议；测试用 mock（成功/各 CutoutError）。

### PetAssetLoader / PetView 渲染（架构 M-1：保持 PetView 纯视图）
- **PetWindowController 持有 `CustomPetStore`**；在 `update()/applyPet()` 时调 `PetAssetLoader.image(selection: PetKind, assetState:, customStore:) -> NSImage` **解析出 NSImage**，传给 PetView。
- **PetView 改为 `resolvedImage: NSImage?` 入参**（替代 `pet: String`），**移除 view body 内的 `PetAssetLoader` 调用**（不再在渲染帧里同步读盘）；nil → SF Symbol 兜底。
- `PetAssetLoader.image(selection:…)`：`.builtin` 走原 PNG 逻辑；`.custom(id)` 从 `customStore.imagePath(id)` 加载，缺失/损坏 → 兜底。
- **轻呼吸动画**（产品 M-1）：PetView 用 `scaleEffect` + `.animation(.easeInOut(duration: 2).repeatForever(autoreverses: true))` 做 ~3% 缩放循环（对内置与照片宠物都生效，成本极低）。圆形上桌用 `clipShape(Circle())`。

### applyPet 迁移（架构 M-2 / 用户 N-12）
- `applyPet` 签名改 `applyPet(_ selection: PetKind)`；**`AppCoordinator.applyConfig` 调用处改 `pw.applyPet(PetSelection.parse(newConfig.selectedPet))`**；删除旧 `String` 重载。tasks 显式列"迁移所有 applyPet(String) 调用 + `swift build` 无旧签名残留"。

### UI（apet）+ 失败不出丑（产品 B-1 / 用户 B-1/M-3）
- 首选项「宠物」区块：内置柴犬/比熊选择 + 「上传照片」(NSOpenPanel png/jpg)。
- **上传动线（明确步骤，用户 B-1）**：选图(1) → `importPhoto` 拷贝+缩放+剥 EXIF(2) → 弹「一键抠图？」对话(3)：
  - 选「抠图」→ 后台 `await cutter.cutout`；**成功** → setCutout + 自动设为当前宠物；**失败**（任一 CutoutError）→ **不设为当前、保持现有宠物不变**，明确提示（按 CutoutError 文案：`noForegroundDetected`→"未识别到宠物主体，请换张主体清晰的照片"；`outputWriteFailed`→"存储空间不足"；`platformUnsupported`→"抠图需 macOS 14+，可直接用原图"；其它→"抠图未成功"）。**绝不把白底方块静默贴桌面**（产品 B-1）。
  - 选「用原图」→ 用 original.png 设为当前（圆形 clip 上桌——这是用户明确选择的"原图直接用"，可接受）。
- **持久状态 + 重试**（用户 M-3）：首选项自定义宠物条目旁显示「✓ 已抠图」/「⚠ 使用原图」+「重新抠图」按钮。

### 测试
纯逻辑 TDD：`PetSelection.parse`（真值表含 `"custom:"`空 id→builtin）、`CustomPetStore`（importPhoto 缩放/剥 EXIF 决策、imagePath 优先 cutout、delete，FileOps mock + idProvider 固定）、抠图各 `CutoutError` 经 mock 验证降级（**失败→保持当前宠物**的决策逻辑抽成可测纯函数）。Vision 真实抠图 + NSOpenPanel + 渲染 + 呼吸动画走手动验证。

---

## 4. 子项 B：多 root 并行扫描

### 现状 → 改造
- **现状**：`AppCoordinator.start()` 只取 `config.dataRoots.first` 建一个 watcher；M1.5 仅健康面板提示。
- **改造**：每个 dataRoot 各建 watcher（共享 ingestor/store，归一键含 root 不撞）；**知情同意**地纳入 `~/.claude-profiles/*`。

### 组件
- **DataRootDiscovery（纯逻辑 + 注入式 FS，AppShellKit，可测）**：`discover(home: String, existing: [DataRoot], fileOps: FileOps) -> DiscoveryResult`。
  - `home` 传**展开后的绝对路径**；existing 的 path 也归一化为展开路径再比较去重（用户 M-6：防 `~/.claude` 与 `/Users/x/.claude` 重复建 watcher）。
  - **只纳入"看起来是 Claude root"的子目录**：`~/.claude-profiles/<x>` 须含 `projects/` 子目录才纳入（架构 M-3：防误建目录/无关目录变 watcher）。
  - **上限 `maxAutoRoots = 16`**：超出截断 + 日志（架构 M-3：防几十个 watcher）。
  - 返回 `DiscoveryResult { roots: [DataRoot], newlyDiscovered: [DataRoot] }`（`newlyDiscovered` = 不在 existing 的，供"首次发现提示"用）。
- **AppCoordinator 改造**：`jsonlWatcher` 单值 → **`jsonlWatchers: [JSONLDirectoryWatcher]`**；`start()` 遍历 `discover(...).roots` 各建 watcher（各自 projectsDir/parse root）；**`stop()`：`jsonlWatchers.forEach { $0.stop() }; jsonlWatchers.removeAll()`**（架构 N-5 防 ARC 泄漏，为未来热重载留口）。
  - 合成 eventId 加 root 前缀：`"jsonl:\(rootLabel):\(sessionId):\(counter)"`（架构 N-1，多 root 可调试）。
- **知情同意（三重收敛：产品 M-2 / 安全 MAJ-2 / 用户 M-7）**：首次发现 `newlyDiscovered` 非空时，弹一次性轻提示（通知或健康面板横幅）："发现并加入 N 个 Claude profile（列出路径），apet **仅读取会话状态**，可在首选项移除。" 首选项数据根列表对自动发现项标「自动发现」标签，可逐条移除（移除写入 config 的排除列表，下次不再自动纳入）。
- **面板 profile 来源**（产品/用户 N-2）：`SessionRowModel.profileTag`（已存在，从 root 派生）在 root 数 > 1 时于会话行显示（如 `[work]`）；单 root 不显示。

### 边界
- 某 root `projects/` 不存在/不可读 → 该 watcher 上报 unreadable，不影响其它。
- 自动发现的 profile 用户移除后，记入 `config` 的排除集，不再纳入。

### 测试
`DataRootDiscovery`（有/无 .claude、profiles 含/不含 projects/、`~` vs 展开去重、超 maxAutoRoots 截断、newlyDiscovered 计算，fileOps mock）纯逻辑 TDD。多 watcher 装配 + 提示 UI 手动；单 watcher 行为已有覆盖。

---

## 5. 子项 C：通知模式可配 + 免打扰

### 现状 → 改造
- **现状**：`NotifyMode { attentionOnly, everyStop }` + `NotificationDecider.decide(…, mode:)` 已实现；`config.notifyMode: String` 无切换 UI；无免打扰。
- **改造**：首选项加模式 Picker（**默认 `attentionOnly`**——产品 N-1）；新增免打扰预设时段。

### 组件
- **DoNotDisturb（纯逻辑，AgentPetCore，可测）**：`struct DNDWindow { var enabled: Bool; var startMin: Int; var endMin: Int }`（分钟 since 午夜，0–1439）+ `func isQuiet(nowMinOfDay: Int) -> Bool`：
  ```
  guard enabled else { return false }
  if startMin == endMin { return false }            // 无效/未设窗口（架构 M-5/用户 M-5：避免 start==end tautology 永久静音）
  if startMin < endMin { return nowMinOfDay >= startMin && nowMinOfDay < endMin }   // 同日
  return nowMinOfDay >= startMin || nowMinOfDay < endMin                            // 跨午夜
  ```
- **now 注入（用户 B-2）**：`NotificationService.consider` 在决定投递前，于**边界**用本地时间算 `nowMinOfDay = Calendar.current` 分钟数（系统时间在 service 边界获取，与现有 `Date()` 用法同级，不入纯逻辑层），调 `DoNotDisturb.isQuiet`；安静期 → 不投递 OS 通知（事件仍更新面板）。不改 `NotificationGate.evaluate` 签名（避免破坏既有 12 个 GateTests）。
- **AppConfig 新字段 + 向后兼容（架构 B-1，关键）**：加 `dndEnabled: Bool`、`dndStartMin: Int`、`dndEndMin: Int`。**必须写自定义 `init(from decoder:)`**，对这三个字段（及未来新字段）用 `decodeIfPresent ?? 默认`，其余字段保持必需——否则旧 `config.json`（无这三 key）触发 `keyNotFound` → `ConfigStore` catch 返回 `defaults` → **静默丢失用户全部配置**。默认：`dndEnabled=false, dndStartMin=0, dndEndMin=0`（产品 N-1 / 用户 N-9）。
- **首选项 UI**：通知区块加 模式 Picker + DND 开关 + **预设选择**（产品 M-4）：「深夜 23:00–07:00」「工作 09:00–18:00」「自定义」（自定义才展开时分 Picker）。跨午夜动态说明文本（用户 N-10）：start>end 显示"每天 HH:mm 至次日 HH:mm 静音"。

### 测试
`DoNotDisturb.isQuiet`（同日/跨午夜/`start==end`→false/`enabled=false`→false/边界 now==start、now==end）真值表 TDD；**`AppConfig` 向后兼容解码测试**（旧 json 无 dnd 字段 → `dndEnabled=false/start=0/end=0` 且其余字段不丢——守护架构 B-1）；DND 静音期 `consider` 不投递的集成边界。UI 手动。

---

## 6. 子项 E：M1.5 技术债

- **hookMarker 常量化（架构 N-2）**：新增 `public enum HookConstants { public static let marker = "apet-1" }`（AppShellKit）；**删除 `AppCoordinator.hookMarker` 静态常量**（其引用处改 `HookConstants.marker`）+ `PreferencesView.hookMarker` 字面量改引用。加一个值断言测试。
- **健康面板异步 IO**：`PreferencesView.refreshHealthStatus` 的同步文件枚举 → `Task.detached(priority: .utility)` 后台执行再 hop `@MainActor` 赋值（避免主线程阻塞）。
- **Swift6 Sendable（策略定死，产品 N-3）**：`NotificationService` 用 **`@preconcurrency import UserNotifications`** 消除 `UNNotificationRequest` 非 Sendable 捕获告警（不留"若成本高"出口）。
- **applyPet 迁移**：见 §3（与照片宠物同批，但调用点迁移属技术债性质，验收含"无旧 String 签名残留"）。

### 测试
`HookConstants.marker` 值断言；异步 IO/Sendable 走 build + 手动。

---

## 7. 实现顺序与并行（避免文件冲突）

触及文件：A=PetView/PetAssetLoader/PetWindowController/Preferences(宠物段)/AppConfig(selectedPet 已有) ; B=AppCoordinator/Preferences(数据根段) ; C=NotificationService/AppConfig/Preferences(通知段) ; E=AppCoordinator/PreferencesView/NotificationService/HookConstants。

**冲突点**：PreferencesWindow（A/B/C/E）、AppCoordinator（B/E）、AppConfig（C）、NotificationService（C/E）。

**策略**：
- **纯逻辑层可并行多子 Agent**：PetSelection、CustomPetStore、ForegroundCutter 协议+CutoutError、DataRootDiscovery、DoNotDisturb、HookConstants 互不相干，同时 TDD。
- **集成/UI 层串行**，顺序 **E → C → B → A**（E 先清债 + HookConstants；C 先动 AppConfig 自定义解码地基；B 多 watcher；A 的 Preferences 宠物段 + 渲染改造最后）。
- 每子项纯逻辑 TDD → 集成 → `swift test` 全绿 → 5 视角子 Agent 评审 → 修订 → 提交。

## 8. 默认值汇总（产品 N-1 / 用户 N-9）

| 配置 | 默认 |
|------|------|
| `notifyMode` | `attentionOnly`（仅需关注才响） |
| `dndEnabled` | `false` |
| `dndStartMin / dndEndMin` | `0 / 0`（无效窗口，不静音） |
| `selectedPet` | `"shiba"` |

## 9. 非目标（M2 不做）

- **安装账本**（推 M3，与卸载流程一起——产品 M-5）。
- AI 照片→手绘宠物（用户选本地抠图；AI 路线留 M2.x 可选，需联网）。
- 多状态精灵帧（照片宠物单图 + 呼吸动画降级）。
- 多 root 的 **hook** 多文件（hook events.ndjson 仍单文件；多 root 仅 jsonl 维度）。
- sidecar 插件执行、公开契约 Schema（M4）。
- DND 日历/会议联动（只做固定预设/自定义时段）。

## 10. 五视角面板评审处置纪要

| 来源 | 级别 | 问题 | 处置 |
|------|------|------|------|
| 架构 B-1 | Blocker | AppConfig synthesized Codable 加字段→旧 config keyNotFound→静默丢全部设置 | §5：自定义 `init(from:)` + decodeIfPresent；§5 向后兼容测试 |
| 安全 BLK-1 / 架构 B-2 | Blocker | Vision macOS14 API 在 v13 上 availability crash 绕过降级 | §3：`@available(14)` + macOS13 `UnavailableForegroundCutter` throw |
| 安全 BLK-2 | Blocker | Vision perform 同步阻塞冻结主线程 | §3：`ForegroundCutter` 协议 `async throws` |
| 产品 B-1 / 用户 B-1·M-3 | Blocker/Major | 抠图失败静默贴白底方块 = 视觉灾难 | §3：失败不设为宠物、保持当前 + 明确提示 + 重试；绝不贴白底 |
| 安全 MAJ-1 | Major | mask→透明 PNG CoreImage 管道未规划（丢 alpha/EXIF 方向） | §3：写清 5 步管道 + EXIF Orientation |
| 安全 MAJ-3 | Major | 无前景主体→generateMaskedImage 产全透明非 throw | §3：`allInstances.isEmpty` → throw noForegroundDetected |
| 产品 M-2 / 安全 MAJ-2 / 用户 M-7 | Major×3 | 多 root 静默纳入=隐私惊吓 | §4：首次发现一次性提示 + 自动发现标签 + 可移除；仅读会话状态 |
| 架构 M-3 | Major | DataRootDiscovery 无结构验证、watcher 无上限 | §4：只纳含 projects/ 子目录 + maxAutoRoots=16 |
| 架构 M-5 / 用户 M-5 | Major | DND start==end tautology 永久静音 | §5：isQuiet guard enabled + start==end→false |
| 架构 M-1 | Major | PetView 纯视图 vs customStore IO | §3：PetWindowController 解析 NSImage，PetView 收 resolvedImage |
| 架构 M-2 / 用户 N-12 | Major | applyPet String→PetSelection 破坏性变更 | §3：AppCoordinator PetSelection.parse 转换 + 迁移 task |
| 产品 M-1 | Major | 单图静态弱于内置动画 | §3：轻呼吸动画（scaleEffect repeatForever） |
| 用户 B-2 | Blocker | DND now 注入接口/时区未定义 | §5：consider 边界算 nowMinOfDay，isQuiet 收 Int，不改 Gate 签名 |
| 用户 B-1 | Blocker | 上传"设为当前"自动 vs 显式歧义 | §3：明确步骤序列 + 抠图取消行为 |
| 产品 M-5 | Major | 账本低价值高复杂 | §1：D 推 M3 |
| 产品 M-4 | Major | DND 时间 Picker 太重 | §5：预设（深夜/工作/自定义） |
| 安全 MIN-1 | Minor | 照片 EXIF/GPS 未剥离 | §3：importPhoto CGImageDestination 剥 EXIF |
| 安全 MIN-2 | Minor | CutoutError 未定义 | §3：CutoutError 枚举差异化 UI |
| 架构 N-1 | Minor | eventId 缺 root | §4：eventId 加 rootLabel |
| 架构 N-2 | Minor | hookMarker 是静态常量非字面量 | §6：删 AppCoordinator.hookMarker → HookConstants |
| 架构 N-4 | Minor | 大图缩放位置未定 | §3：importPhoto 内缩放 ≤512（抠图前） |
| 架构 N-5 | Minor | stop() 漏 removeAll ARC 泄漏 | §4：forEach stop + removeAll |
| 用户 M-4 | Major | PetSelection "custom:" 空 id 未定义 | §3：→ builtin("shiba") |
| 用户 M-6 | Major | DataRootDiscovery 去重路径归一化 | §4：展开路径去重 |
| 用户 N-9/N-10/N-11 | Minor | dnd 默认/跨午夜 UI 文本/idProvider 类型 | §8/§5/§3 |
| 产品 N-3 | Minor | Sendable 策略模糊 | §6：定死 `@preconcurrency` |
| 安全 MIN-3 | Minor | NSOpenPanel 沙盒 | §3：completionHandler 内同步拷贝注释 |

# apet M2 设计：宠物扩展 + 多源

> 状态：草案（待 5 视角面板评审）
> 日期：2026-06-28
> 前序：`2026-06-27-apet-design.md`（§11 里程碑 M2）+ `2026-06-28-apet-onboarding-jsonl-menubar-design.md`（M1.5）
> 用户决策：照片宠物 = **本地 Vision 抠图 + 原图直接用**（**不做 AI 手绘**，零网络零成本）；M2 全量自主推进。

## 1. 背景

M1（地基+桌宠）与 M1.5（jsonl 兜底+常规体验）已上线（main，315 测试）。M2 把上位设计 §11 的「宠物扩展 + 多源」补齐，分 5 个**独立子项**，各自 spec 段落 → 可独立计划/实现：

| 子项 | 一句话 |
|------|--------|
| **A 照片宠物** | 上传宠物照片 → 桌宠；可选一键抠图（本地 Vision）；单图降级模式 |
| **B 多 root 并行** | 同时扫 `~/.claude` + `~/.claude-profiles/*`，多 profile 用户不再空面板 |
| **C 通知模式可配** | 「需关注才响」/「每轮结束都响」可切 + 免打扰时段 |
| **D 安装账本** | 记录 hook 安装触达的副作用，卸载按账本逆向清理 + 报残留 |
| **E M1.5 技术债** | hookMarker 常量化 / 健康面板异步 IO / Swift6 Sendable |

## 2. 全局约束（沿用）

- 零外部依赖（仅 Foundation/AppKit/SwiftUI/Vision——Vision 是系统框架，不算第三方）。
- 纯逻辑不用 `Date()`，`now: Double` 注入。
- 系统副作用（Vision 抠图、文件 IO、定时器）用**协议缝 + mock** 隔离；纯逻辑全 TDD。
- 既有 315 测试零破坏；既有不变量（唯一 seq 源、ended 不复活、jsonl 不发通知、source 隔离）不动。
- 照片宠物**零网络**：不调用任何远端（不做 bl image edit / AI）。

---

## 3. 子项 A：照片宠物

### 现状 → 改造
- **现状**：`PetView.petImage` 调 `PetAssetLoader.image(pet: String, assetState:)`，`pet ∈ {"shiba","bichon"}` 只加载内置 `Resources/pets/<pet>/<state>.png`；`PetWindowController.currentPet: String` + `applyPet`；`config.selectedPet: String`。
- **改造**：`selectedPet` 扩展取值空间 `"shiba" | "bichon" | "custom:<id>"`；新增自定义宠物的上传/抠图/存储/加载；照片宠物为**单图降级**（所有状态共用同一张图，靠状态点+角标区分，符合上位「上传降级模式」）。

### 组件
- **PetSelection（纯逻辑，AgentPetCore，可测）**：解析 `selectedPet` 字符串 → `enum PetKind { case builtin(String); case custom(id: String) }`。非法/空 → 默认 `.builtin("shiba")`。
- **CustomPetStore（纯逻辑 + 注入式 FS，AppShellKit）**：管理自定义宠物目录 `~/Library/Application Support/AgentPet/pets-custom/<id>/`，含 `original.png`、可选 `cutout.png`。能力：`importPhoto(srcPath) -> id`（拷贝+生成 id）、`list() -> [id]`、`imagePath(id) -> String?`（优先 cutout.png 否则 original.png）、`delete(id)`。id 用内容/时间派生（不用 `Date()`：用注入的 `idProvider` 或文件名计数）。FS 操作经 `protocol FileOps` 注入，纯逻辑测路径决策。
- **ForegroundCutter（协议，AppShellKit）**：`protocol ForegroundCutter { func cutout(srcPath: String, dstPath: String) throws }`；真实实现 `VisionForegroundCutter` 用 `VNGenerateForegroundInstanceMaskRequest`（macOS 14+）抠主体写 PNG；失败抛错。**纯逻辑层只依赖协议**；测试用 mock（成功/失败/超时）。抠图失败 → 降级用 `original.png`（不阻断）。
- **PetAssetLoader 扩展**：`image(selection: PetSelection, assetState:, customStore:) -> NSImage`——`.builtin` 走原逻辑；`.custom(id)` 从 `customStore.imagePath(id)` 加载，缺失 → SF Symbol 兜底。圆形上桌靠 SwiftUI `clipShape`（加载层不预处理）。
- **UI（apet）**：首选项「宠物」区块加：内置柴犬/比熊选择 + 「上传照片」按钮（NSOpenPanel 选 png/jpg）→ 导入 → 弹「一键抠图」可选 → 设为当前。`PetWindowController.applyPet` 接受 PetSelection。

### 数据流
选图 → `CustomPetStore.importPhoto` 拷到 app support → （可选）`ForegroundCutter.cutout` 写 cutout.png → `config.selectedPet="custom:<id>"` 保存 → `PetWindowController.applyPet(.custom(id))` → PetView 用 `imagePath` 圆形渲染。

### 边界
- 抠图失败/Vision 不可用 → 用原图，UI 提示「抠图未成功，用原图」。
- 照片缺失/损坏 → SF Symbol 兜底，不崩。
- 大图 → 导入时缩放到合理尺寸（如 ≤512px）省内存。

### 测试
纯逻辑 TDD：`PetSelection`（解析真值表）、`CustomPetStore`（导入/列举/imagePath 优先 cutout/删除，FileOps mock）、抠图降级（ForegroundCutter mock 失败→用 original）。Vision 真实抠图 + NSOpenPanel + 渲染走手动验证。

---

## 4. 子项 B：多 root 并行扫描

### 现状 → 改造
- **现状**：`AppCoordinator.start()` 只取 `config.dataRoots.first` 建**一个** `JSONLDirectoryWatcher`；M1.5 仅在健康面板提示「发现其他 profile」。
- **改造**：对**每个** dataRoot 各建一个 watcher（共享同一 ingestor/store，归一键含 root 不撞）；启动时自动发现 `~/.claude-profiles/*` 纳入扫描。

### 组件
- **DataRootDiscovery（纯逻辑 + 注入式 FS，AppShellKit）**：`discover(home:, existing: [DataRoot], fileOps:) -> [DataRoot]`——返回 `~/.claude`（若存在）+ `~/.claude-profiles/*` 每个子目录，去重合并 existing。纯函数，FS 经 fileOps mock。
- **AppCoordinator 改造**：`jsonlWatcher` 单值 → `jsonlWatchers: [JSONLDirectoryWatcher]`；`start()` 遍历 `discoveredRoots` 各建 watcher（各自 projectsDir = `<root>/projects`、parse root = 该 root）；`stop()` 全部 stop。`applyScanResult` 不变（已按 key 融合）。
- **首选项**：数据根列表展示所有（含自动发现的），可手动增删；健康面板「发现其他 profile」提示改为「已纳入 N 个数据根」。

### 边界
- 某 root 的 `projects/` 不存在/不可读 → 该 watcher 上报 unreadable，不影响其它 root。
- root 数量多（>10）→ 每 8s 扫所有，IO 可接受（末尾窗口读）；如成本高可加并发限制（YAGNI，先不做）。

### 测试
`DataRootDiscovery`（有/无 .claude、有/无 profiles、去重，fileOps mock）纯逻辑 TDD。多 watcher 装配走手动 + 现有 watcher 单测覆盖单个行为。

---

## 5. 子项 C：通知模式可配 + 免打扰

### 现状 → 改造
- **现状**：`NotifyMode { attentionOnly, everyStop }` + `NotificationDecider.decide(…, mode:)` 已实现；`config.notifyMode: String` 存在但**首选项无切换 UI**；无免打扰。
- **改造**：首选项加通知模式 Picker；新增**免打扰时段**（DND）。

### 组件
- **DoNotDisturb（纯逻辑，AgentPetCore，可测）**：`struct DNDWindow { var enabled: Bool; var startMin: Int; var endMin: Int }`（分钟 since 午夜）；`func isQuiet(nowMinOfDay: Int) -> Bool`，正确处理**跨午夜**（如 22:00–08:00）。
- **NotificationGate 集成**：在已有的通知投递 gate（`NotificationService.consider`/`NotificationGate`）前置 DND 检查——DND 安静期 `shouldNotify=false`（事件仍正常更新面板，只是不弹 OS 通知）。now 注入（取当前分钟）。
- **AppConfig**：加 `dndEnabled: Bool`、`dndStartMin: Int`、`dndEndMin: Int`（带默认值，Codable 向后兼容——解码缺字段用默认）。
- **首选项**：通知区块加 模式 Picker + DND 开关 + 起止时间 Picker。

### 边界
- DND 跨午夜：`start > end` 表示跨午夜，`isQuiet = now>=start || now<end`；`start==end` 视为全天/空（明确定义为不静音）。
- AppConfig 加字段需保证旧 config.json 解码不失败（缺字段 → 默认，`decodeIfPresent`）。

### 测试
`DoNotDisturb.isQuiet`（同日窗口/跨午夜/边界 start==end/now 正好等于 start/end）纯逻辑 TDD；`AppConfig` 向后兼容解码测试（旧 json 无 dnd 字段 → 默认值）。UI 手动。

---

## 6. 子项 D：安装账本

### 现状 → 改造
- **现状**：`HookInstaller.install` 写 `settings.json` + 备份 `.apet.bak`，但**无账本**；卸载靠 marker 移除条目。
- **改造**：安装时把触达的副作用记入**账本**（写了哪个 settings.json、备份路径、装了哪些 hook 事件、marker）；卸载读账本逆向清理并报「账本有但已不在」的残留。强调（上位 §设计）：账本是**透明与可清理**，不是安全机制——真正的控制是「安装前门控阻止」（已实现）。

### 组件
- **InstallLedger（纯逻辑 model，AppShellKit——与 HookInstaller/LedgerStore 同模块，可测）**：`struct LedgerEntry: Codable, Equatable { let kind: String; let path: String; let marker: String; let backupPath: String?; let ts: String }`；`struct InstallLedger: Codable, Equatable { var entries: [LedgerEntry] }` + 纯函数 `appending(_:)`、`removing(marker:path:)`、`residuals(existing: (String)->Bool) -> [LedgerEntry]`（账本有但 existing 返回 false 的）。
- **IO 壳（AppShellKit）**：`LedgerStore`：读写 `~/Library/Application Support/AgentPet/install-ledger.json`（注入式 FS）。
- **HookInstaller 集成**：install 成功 → `LedgerStore` 追加 entry；uninstall → 读账本，移除对应 entry，返回残留供 UI 报告。
- **首选项**：「已安装项」区块展示账本，可「按账本清理」。

### 边界
- 账本与实际不一致（用户手改了 settings.json）→ `residuals` 报告，不强删。
- 账本文件损坏 → 解码失败时重置为空账本 + 日志（不崩）。

### 测试
`InstallLedger`（appending/removing/residuals 纯函数真值表）TDD；`LedgerStore` 临时目录读写 + 损坏降级测试。

---

## 7. 子项 E：M1.5 技术债

- **hookMarker 常量化**：`AppCoordinator.hookMarker` 与 `PreferencesView.hookMarker` 两处 `"apet-1"` → 提取到单一 `public enum HookConstants { static let marker = "apet-1" }`（AppShellKit），两处引用。
- **健康面板异步 IO**：`PreferencesView.refreshHealthStatus` 的同步文件枚举 → `Task.detached` 后台执行再 hop 回 @MainActor 赋值（避免主线程阻塞）。
- **Swift6 Sendable**：`NotificationService` 里 `UNNotificationRequest` 非 Sendable 捕获 → 加 `@preconcurrency import UserNotifications` 或在 Task 边界做 sendable 包装。**优先级最低**（Swift5 仅 warning），若成本高可只留注释 TODO。

### 测试
hookMarker 常量化编译即验证；异步 IO/Sendable 走 build + 手动。`HookConstants` 可加一个值断言测试。

---

## 8. 实现顺序与并行（避免文件冲突）

子项触及文件：A=PetView/PetAssetLoader/PetWindowController/Preferences(宠物段) ; B=AppCoordinator ; C=NotificationDecider/Gate/AppConfig/Preferences(通知段) ; D=HookInstaller/Preferences(已安装段) ; E=AppCoordinator/PreferencesView/NotificationService。

**冲突点**：PreferencesWindow（A/C/D/E 都碰）、AppCoordinator（B/E）。

**策略**：纯逻辑层可并行（PetSelection/CustomPetStore、DataRootDiscovery、DoNotDisturb、InstallLedger、HookConstants 互不相干，可同时多子 Agent TDD）；UI/集成层（Preferences/AppCoordinator）**串行**，按 E→B→C→D→A 顺序合入（E 先清债减小后续 diff；A 的 Preferences 宠物段最后加）。

每个子项纯逻辑 TDD → 集成 → `swift test` 全绿 → 5 视角子 Agent 评审 → 修订 → 提交。

## 9. 非目标（M2 不做）

- AI 照片→手绘宠物（bl image edit）——用户已选本地抠图，AI 路线搁置（未来 M2.x 可加）。
- 多状态精灵帧（照片宠物只单图降级）。
- 多 root 的 **hook** 多文件（hook events.ndjson 仍单文件；多 root 仅 jsonl 兜底维度）。
- sidecar 插件执行、公开契约 Schema（属 M4）。
- 免打扰的「会议日历联动」等高级 DND（只做固定时段）。

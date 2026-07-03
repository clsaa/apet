# 面板 UX 8 视角评审报告(feature/panel-ux)

日期:2026-07-04 · 视角:架构/交互/UI/产品/AI/用户/测试/开源(8 子agent)

## Blocker(2)
1. **B1 对 iTerm2/Terminal 失效**(AI):TerminalFocusService 把 `.targetGone` 兜底激活后改写成 `.activatedOnly` → 调用方判「到达」标已读 → 主力终端 tab 关掉后点一下照样丢等你会话。B1 的 targetGone 分支对主力终端是死代码。
2. **桌宠死 tab 栏**(架构/交互/产品):SessionPanel.body 无条件渲染 tabBar,但 PetPanelRootView 不传 tab/分组回调 → 默认 pet 模式下 tab/分组/+/加入分组全 no-op。

## Major
- F 可缩放窗口半成品:PanelRootView 写死 .frame(width:320) 让变宽失效;窗口泄漏(hidesOnDeactivate orderOut 不 close,重开新建覆盖旧窗口,close 后不置 nil);.statusBar 层级压自身 NSAlert;无 minSize;关闭钮未隐藏;hidesOnDeactivate 与可缩放常驻语义矛盾。
- config clobber:面板旁路写 config(selectedTab/sessionGroups/panelW/H),Preferences 持旧快照 performSave 整份覆盖 → 面板改动丢失。
- 删组无确认(spec §6 要求)+ 建组无反馈/非法名静默。
- Cursor 硬编码成 VSCode、Warp-Preview 硬编码 Warp-Stable → 错图标/错激活/错 ack(hook 应读 __CFBundleIdentifier)。
- 文档未同步 README/CLAUDE.md(测试计数、会话管理条目、路线图)。
- 测试假绿:AppConfig 4 新字段零测;SessionMeta.merge groups 排序被断言里 .sorted() 掩盖;organizeFlat read/group/搜索叠加/收藏排序未测;organizeFlat→mapper 集成链未测;PathAbbreviator home-非边界守卫。
- pinned 排序不稳定(无 offset tiebreak,rest 有)——一致性洞。

## Minor
E10 ⋯ 溢出入口未做(需实现或回写遗留)；CopyHUD 主屏正中离操作点远+多屏错屏；U3 桌宠侧未改(仍塌陷)；tab 计数不随搜索；勾选态空 systemImage 左缘不齐；static AppIconCache/CopyHUD 未 @MainActor；魔数未具名；公开 API 注释夹带 M3-D/U1 行话；emptyState 写死 320；E11 已读消歧 tooltip 未落 tab。

## 正面(勿回退)
纯逻辑层干净单测友好、硬约束落位；U1 跨tab常驻 spec/plan/实现/测试四处一致;B1/B2 双入口同构;诚实降级/防连击保留。

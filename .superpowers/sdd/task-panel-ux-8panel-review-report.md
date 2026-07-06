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

---

## 修复结果(8 视角评审后,feature/panel-ux)

**Blocker(2)全修:**
1. B1 对 iTerm2/Terminal 失效 → 新增 `FocusResult.missedButActivated` 区分「精确跳转未命中的兜底激活」vs「计划内 activate-only」,只有 `.focused`/`.activatedOnly` 标已读,兜底激活保留未读。
2. 桌宠死 tab → 桌宠面板接通 tab/分组(与菜单栏共用闭包),`showsTabBar` 开关备用;默认 pet 模式旗舰功能可用。

**Major 全修:**
- 可缩放窗口:去除内容写死 320(拖宽真生效)、窗口复用不泄漏(orderOut 非新建)、`.floating` 层级不压 NSAlert、borderless 去残留关闭钮、contentMinSize 夹逼。
- config clobber:applyConfig 保留面板私有字段 live 值。
- 删组二次确认 + 建组切到新 tab + 非法名提示。
- Cursor/Warp-Preview:hook 读 `__CFBundleIdentifier` 真 bundleId;TerminalKind.bundleId 降兜底+维护注释。
- 文档同步:README/CLAUDE.md 补 tab/分组/终端图标/悬停收藏/可缩放,测试计数 752。
- 测试假绿:AppConfig 4 字段、merge 排序不自掩盖、organizeFlat read/group/收藏稳定/集成链、PathAbbreviator 边界、isValidName 字素;pinned 改稳定排序。

**Minor:** tab 计数随搜索收敛、勾选态对齐、pinned「始终置顶」说明、@MainActor 隔离、E11 已读 tab 消歧 tooltip、CopyHUD 改鼠标屏顶部、U3 桌宠已读常驻置灰。

**遗留(spec §9 已回写):** E10 悬停 ⋯ 溢出入口未做;hidesOnDeactivate 常驻取舍待用户定;桌宠侧不可缩放。

**最终:752 测试全绿,build 通过,App 运行无崩溃。**

---

## 巩固评审(2026-07-06,架构+测试双视角,近期未审工作)

Blocker①(已修):不可信 wire pid 经 pid_t(Int) 溢出 trap → 60s 崩溃循环;TtyLiveness.safeKill0 exactly 转换,classify 溢出判 unknown。
Major②(已修):menubar 点击预关窗 → 跳转失败提示条永不可见+烧 hookHint 节流;改成功才 orderOut,失败留窗就地显示(与桌宠对齐)。
Major③(已修):StaleDirPrefilter subagent 盲区(枚举器排除 agent-* 文件,折叠分支死代码)→ 改 subagents 目录存在性豁免。
Major④(已修):dbBacked stop 预置已读打穿 OpenCode 插件红点 → guard source != .hook。
Major⑤(已修):插件不过滤子会话 → session.created 记 parentID 过滤;附 busy 3s 去抖(洪泛)。
Minor(已修):noticeCopied 收编 PanelUIState;resetTransient 开面板清半途态;收藏豁免 dead 快清;hookCommand 完整单引号引用;告知文案补 busy。
Minor(记录未修):pid 复用+tty 占用的永久 alive(建议 sysctl 进程启动时间,已注释);pet 侧 hookHint 恒 false(pet 无 throttle 实例,待统一)。

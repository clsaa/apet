# M3-A1 多终端 + 开机自启 —— 实现报告

分支 `feature/m3-a1-multiterm-autolaunch`。基线 447 测试 → 完成 488 测试（+41），全绿；`swift build` 无新增警告。

## 交付（4 commit）

| commit | 内容 |
|---|---|
| `b26870b` | 终端能力分级单一事实源 `TerminalCapability`/`TerminalCapabilities` + 修 `SessionRowModel` 对 `.terminal` 的判定分歧 |
| `a375a56` | `TerminalAppLocator`（Terminal.app 窗口级，tty 白名单参数化）+ planner 接线 |
| `f480068` | 扩展 Ghostty/VSCode 终端类型 + hook 采集 tty + 降级终端 UI 提示 |
| `83877f1` | 开机自启（`LoginItemDecider` + `SMAppService` 缝 + 首选项开关） |

## 关键取舍与观察

1. **发现并修掉一处潜伏 bug**：`SessionRowModel` 原判 `.terminal` 为「精确」（activateOnly=false），但 planner 实际只 `activateBundle` Terminal.app——两处各判各的。M3-A1 把「终端能被定位到多精确」收口成 `TerminalCapabilities.capability(for:)` 单一纯函数，planner 与 rowmodel 共同消费，从根上消除分歧。升级 Terminal.app 到窗口级 osascript 后，`.terminal` 判为 `preciseWindow`（非 activateOnly），前后自洽。

2. **tty 采集用 `ps -o tty= -p $PPID`**：hook 的 stdin 是 payload（非 tty），`tty` 命令不可用。改读父进程（跑 Claude 的终端）的控制 tty。**局限**：进程脱离控制终端时得到 `??`/空，python 侧校验 `/dev/tty`+alnum 后才写入，非法一律丢弃（已在沙盒验证：`ttys042→/dev/ttys042`、`??→丢`、`bad;rm→丢`、`/dev/ttys009→留`）。Terminal.app 无 tty 时优雅降级为激活应用。

3. **安全红线**：所有终端标识（iTerm2 session id / Terminal tty）经白名单校验后以 argv 传入 osascript，脚本体零内插。`TTYPath` 红队用例断言 `;`/`$()`/反引号/空格/双引号被拒；planner 对非法 tty 兜底 activateBundle 而非抛异常。

4. **VSCode/Cursor**：二者都设 `TERM_PROGRAM=vscode`，统一 `kind=vscode`、能力 `activateOnlyManualTab`（仅激活应用 + 需手动切标签）。面板显「仅激活·手动切标签」区分于普通「仅激活」。

5. **开机自启 SMAppService**：真值在系统，`@State` 只作 UI 镜像；决策 `LoginItemDecider`（4 组合矩阵）在 core、副作用在注入的 `LoginItemControlling`（Mock 覆盖 register/unregister/throw/noop 五态）。**未签名/开发构建下 `SMAppService.mainApp.register()` 可能因缺 bundle 签名而失败**——UI 已做失败回滚 + 引导去「系统设置 › 登录项」。正式签名分发后此路径才稳定，需在签名构建上手测确认。

## hook 无单测——手测覆盖

`apet-emit-event.sh` 无 XCTest。已用 mock payload 沙盒验证：ghostty/vscode 正确产出 `terminal.kind`+bundleId；Apple_Terminal 产出 `terminal`；tty 归一化白名单四态正确。**仍需真机手测**：真实 Terminal.app 会话点击应选中对应窗口；Ghostty/VSCode 会话点击激活应用且面板显提示。

## 遗留

- VSCode 内置终端无法精确到 tab（产品取舍：激活应用 + 提示手动切）。
- 开机自启在签名分发构建上的稳定性待手测确认。
- Warp/Ghostty 的 `bundleId` 采用常见值（`dev.warp.Warp`/`com.mitchellh.ghostty`），若厂商变更需跟进。

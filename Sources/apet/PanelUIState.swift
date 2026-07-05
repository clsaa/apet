import SwiftUI

/// 面板的 UI 触发状态(摘要/重命名/建组/删组确认)。
///
/// **为什么不是 @State**:面板 rootView 在每次 store 变更(几秒一次)被
/// `panelHosting?.rootView = makePanelRootView()` 整树替换;NSMenu(右键/⋯)持有的是
/// **菜单打开那一刻**视图树的闭包——树被替换后点菜单项,写进的是已废弃存储,活树看不见
/// (实测:`menu quick clicked` 有日志、`task fired` 无,banner 不出现;重命名时灵时不灵)。
/// 改为控制器持有的 ObservableObject:对象跨替换存活,菜单闭包怎么写都落在同一处,
/// @Published 驱动活树重渲染。搜索框 filter 等「只被活树里的控件写」的状态仍可用 @State。
@MainActor
final class PanelUIState: ObservableObject {
    // 摘要(快速/AI)
    @Published var summaryRowId: String? = nil
    @Published var summaryOutcome: SummaryOutcome? = nil
    @Published var summaryUseAI = false
    @Published var summaryNonce = 0
    // 行内重命名
    @Published var renamingId: String? = nil
    @Published var renameText = ""
    // 建组内联输入(tab栏 + / 行右键新建)
    @Published var isCreatingGroup = false
    @Published var newGroupText = ""
    @Published var creatingGroupAttachId: String? = nil
    // 删组二段式确认
    @Published var confirmDeleteGroup: String? = nil
}

/// 摘要展示态(loading/结果/错误)。
enum SummaryOutcome { case loading, text(String), error(String) }

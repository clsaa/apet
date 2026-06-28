import XCTest
@testable import AppShellKit

final class MenuBarMenuModelTests: XCTestCase {
    func test_emptyState_returnsInactiveSession() {
        let rows = MenuBarMenuModel.rows(runningCount: 0, waitingCount: 0)

        let firstRow = rows.first
        XCTAssertEqual(firstRow?.title, "暂无活跃会话")
        XCTAssertEqual(firstRow?.command, .sessionSummary)
        XCTAssertEqual(firstRow?.enabled, false)
        XCTAssertEqual(firstRow?.shortcut, nil)
    }

    func test_activeState_returnsSummaryWithCounts() {
        let rows = MenuBarMenuModel.rows(runningCount: 2, waitingCount: 1)

        let firstRow = rows.first
        XCTAssertEqual(firstRow?.title, "2 进行中 · 1 等待中")
        XCTAssertEqual(firstRow?.command, .sessionSummary)
        XCTAssertEqual(firstRow?.enabled, false)
        XCTAssertEqual(firstRow?.shortcut, nil)
    }

    func test_rowsReturnFourItems() {
        let rows = MenuBarMenuModel.rows(runningCount: 0, waitingCount: 0)

        XCTAssertEqual(rows.count, 4)
    }

    func test_preferencesRow() {
        let rows = MenuBarMenuModel.rows(runningCount: 0, waitingCount: 0)

        let preferencesRow = rows[1]
        XCTAssertEqual(preferencesRow.title, "首选项…")
        XCTAssertEqual(preferencesRow.command, .preferences)
        XCTAssertEqual(preferencesRow.enabled, true)
        XCTAssertEqual(preferencesRow.shortcut, ",")
    }

    func test_aboutRow() {
        let rows = MenuBarMenuModel.rows(runningCount: 0, waitingCount: 0)

        let aboutRow = rows[2]
        XCTAssertEqual(aboutRow.title, "关于 apet")
        XCTAssertEqual(aboutRow.command, .about)
        XCTAssertEqual(aboutRow.enabled, true)
        XCTAssertEqual(aboutRow.shortcut, nil)
    }

    func test_quitRow() {
        let rows = MenuBarMenuModel.rows(runningCount: 0, waitingCount: 0)

        let quitRow = rows[3]
        XCTAssertEqual(quitRow.title, "退出 apet")
        XCTAssertEqual(quitRow.command, .quit)
        XCTAssertEqual(quitRow.enabled, true)
        XCTAssertEqual(quitRow.shortcut, "q")
    }

    func test_fullRowsEquality() {
        let rows = MenuBarMenuModel.rows(runningCount: 0, waitingCount: 0)

        let expectedRows: [MenuRow] = [
            MenuRow(title: "暂无活跃会话", command: .sessionSummary, enabled: false, shortcut: nil),
            MenuRow(title: "首选项…", command: .preferences, enabled: true, shortcut: ","),
            MenuRow(title: "关于 apet", command: .about, enabled: true, shortcut: nil),
            MenuRow(title: "退出 apet", command: .quit, enabled: true, shortcut: "q"),
        ]

        XCTAssertEqual(rows, expectedRows)
    }

    func test_fullRowsWithActiveSessions() {
        let rows = MenuBarMenuModel.rows(runningCount: 3, waitingCount: 2)

        let expectedRows: [MenuRow] = [
            MenuRow(title: "3 进行中 · 2 等待中", command: .sessionSummary, enabled: false, shortcut: nil),
            MenuRow(title: "首选项…", command: .preferences, enabled: true, shortcut: ","),
            MenuRow(title: "关于 apet", command: .about, enabled: true, shortcut: nil),
            MenuRow(title: "退出 apet", command: .quit, enabled: true, shortcut: "q"),
        ]

        XCTAssertEqual(rows, expectedRows)
    }
}

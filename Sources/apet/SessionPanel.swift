import SwiftUI
import AppShellKit

// MARK: - SessionPanel

/// SwiftUI list of active sessions.
///
/// Used by both the menu-bar popover and (later) the floating pet panel.
/// Pure view: no side-effects, no store access — driven entirely by ``SessionRowModel`` values
/// and the `onTap` callback provided by the caller.
struct SessionPanel: View {
    /// Rows to display, mapped from `Session` via `SessionRowMapper`.
    let rows: [SessionRowModel]
    /// Called with the row's stable `id` when the user taps a row.
    let onTap: (String) -> Void

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            rowList
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Text("没有活跃会话")
            .foregroundStyle(.secondary)
            .frame(width: 320)
            .padding(.vertical, 20)
    }

    // MARK: - Row list

    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    SessionRowCell(row: row)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(row.id) }

                    if row.id != rows.last?.id {
                        Divider()
                            .padding(.leading, 30)
                    }
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 400)
    }
}

// MARK: - SessionRowCell

private struct SessionRowCell: View {
    let row: SessionRowModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // State dot
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                // Title line: bold name + optional profile chip + "仅激活" label
                HStack(spacing: 5) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if let tag = row.profileTag {
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.13))
                            .cornerRadius(4)
                            .lineLimit(1)
                    }

                    if row.isInferred {
                        Text("推断")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if row.activateOnly {
                        Text("仅激活")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 0)
                }

                // Subtitle line: cwd path
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var dotColor: Color {
        let base: Color
        switch row.dot {
        case .running:     base = .green
        case .attention:   base = .orange
        case .doneWaiting: base = .red
        case .stale:       base = .gray
        }
        // Inferred (jsonl waiting) rows get a muted dot so they don't look as urgent
        // as hook-sourced sessions where we have live confirmation of the state.
        return row.isInferred ? base.opacity(0.45) : base
    }
}

// MARK: - Preview

struct SessionPanel_Previews: PreviewProvider {
    static var previews: some View {
        SessionPanel(
            rows: [
                SessionRowModel(
                    id: "claude-code|~/.claude|s1",
                    title: "my-project",
                    subtitle: "/Users/dev/my-project",
                    profileTag: "work",
                    dot: .running,
                    activateOnly: false
                ),
                SessionRowModel(
                    id: "claude-code|~/.claude|s2",
                    title: "other-task",
                    subtitle: "/Users/dev/other",
                    profileTag: nil,
                    dot: .attention,
                    activateOnly: false
                ),
                SessionRowModel(
                    id: "claude-code|~/.claude|s3",
                    title: "warp-session",
                    subtitle: "/Users/dev/warp",
                    profileTag: nil,
                    dot: .doneWaiting,
                    activateOnly: true
                ),
                SessionRowModel(
                    id: "claude-code|~/.claude-profiles/personal|s4",
                    title: "stale-one",
                    subtitle: "",
                    profileTag: "personal",
                    dot: .stale,
                    activateOnly: false
                ),
            ],
            onTap: { _ in }
        )
        .frame(width: 320)
    }
}

import SwiftUI
import AppShellKit

// MARK: - PetView

/// Floating pet window content: pet image + state dot + badge + speech bubble.
/// Pure view driven by ``PetPresentation`` — no store access.
struct PetView: View {
    let presentation: PetPresentation
    let pet: String

    @State private var bobOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 4) {
                // Speech bubble (calling state)
                if let bubble = presentation.bubble {
                    bubbleView(text: bubble)
                }

                // Pet image with optional badge
                ZStack(alignment: .topTrailing) {
                    petImage
                        .offset(y: bobOffset)
                        .onAppear {
                            withAnimation(
                                .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                            ) {
                                bobOffset = -6
                            }
                        }

                    if let badge = presentation.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                presentation.emphasize ? Color.orange : Color.red
                            )
                            .clipShape(Capsule())
                            .offset(x: 4, y: -4)
                    }
                }

                // 始终显示的运行/完成计数（用户反馈：时刻显示，无需点击）
                countChip
            }
            .padding(8)
        }
        .frame(width: 140, height: 160)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var petImage: some View {
        let nsImage = PetAssetLoader.image(pet: pet, assetState: presentation.assetState)
        Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 96, height: 96)
    }

    /// 常驻计数条（4 段）：🟢 在跑 · 🔴 未读 · 🟡 已读 · ⚪ 闲置。每段始终显示（即便为 0）。
    @ViewBuilder
    private var countChip: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("\(presentation.runningCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }
            HStack(spacing: 3) {
                Circle().fill(presentation.emphasize ? Color.orange : Color.red).frame(width: 7, height: 7)
                Text("\(presentation.doneCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }
            HStack(spacing: 3) {
                Circle().fill(Color.yellow).frame(width: 7, height: 7)
                Text("\(presentation.readCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }
            HStack(spacing: 3) {
                Circle().fill(Color.gray).frame(width: 7, height: 7)
                Text("\(presentation.idleCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color(NSColor.windowBackgroundColor).opacity(0.9)).shadow(radius: 2)
        )
        .help("绿=进行中 · 红=停下等你/未读 · 黄=已读 · 灰=闲置")
    }

    @ViewBuilder
    private func bubbleView(text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.92))
                    .shadow(radius: 4)
            )
    }
}

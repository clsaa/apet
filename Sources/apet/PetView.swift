import SwiftUI
import AppShellKit

// MARK: - PetView

/// Floating pet window content: pet image + state dot + badge + speech bubble.
/// Pure view driven by ``PetPresentation`` — no store access.
struct PetView: View {
    let presentation: PetPresentation
    /// Pre-resolved image passed in by ``PetWindowController``; avoids asset loading inside the view.
    let resolvedImage: NSImage?
    /// 是否为用户上传的照片宠物。内置与自定义宠物现统一圆形裁剪（B3 起内置 PNG 已透明），
    /// 该标志暂保留供未来按来源区分渲染之用。
    var isCustomPet: Bool = false
    /// 精简条模式：仅渲染 countChip，不显示宠物图、气泡、呼吸动画。
    /// 窗口尺寸由 ``PetWindowController`` 根据此标志调整。
    var compact: Bool = false

    @State private var bobOffset: CGFloat = 0

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    // MARK: - Full pet body (pet + bubble + countChip)

    private var fullBody: some View {
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

    // MARK: - Compact body (only countChip)

    private var compactBody: some View {
        HStack {
            Spacer(minLength: 0)
            countChip
            Spacer(minLength: 0)
        }
        .frame(width: 160, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.88))
                .shadow(radius: 3)
        )
    }

    // MARK: - Subviews

    @ViewBuilder
    private var petImage: some View {
        let fallback = NSImage(systemSymbolName: "pawprint.fill",
                               accessibilityDescription: "pet") ?? NSImage()
        let nsImage = resolvedImage ?? fallback
        // 内置宠物 PNG 已处理为透明背景（B3），与自定义照片宠物统一圆形裁剪。
        Image(nsImage: nsImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 96, height: 96)
            .clipShape(Circle())
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

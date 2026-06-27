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

                // State dot
                stateDot
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

    @ViewBuilder
    private var stateDot: some View {
        switch presentation.assetState {
        case "busy":
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case "calling":
            Circle()
                .fill(presentation.emphasize ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
        default:
            Color.clear.frame(width: 8, height: 8)
        }
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

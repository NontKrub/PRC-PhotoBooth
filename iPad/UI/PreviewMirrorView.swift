import SwiftUI
import CoreImage

// Shows the live camera preview streamed from the Mac.
struct PreviewMirrorView: View {
    @EnvironmentObject private var vm: iPadViewModel
    let targetAspectRatio: CGFloat?

    init(targetAspectRatio: CGFloat? = nil) {
        self.targetAspectRatio = targetAspectRatio
    }

    var body: some View {
        GeometryReader { geo in
            let viewportSize = viewportSize(in: geo.size)
            ZStack {
                Color.black

                previewContent
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .clipped()
                    .overlay {
                        if let targetAspectRatio,
                           targetAspectRatio.isFinite,
                           targetAspectRatio > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(.white.opacity(0.7), lineWidth: 2)
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var previewContent: some View {
        if let image = vm.latestPreviewImage {
            Image(image, scale: 1, label: Text("Preview"))
                .interpolation(.high)
                .resizable()
                .scaledToFill()
                .scaleEffect(x: vm.isMirrored ? -1 : 1, y: 1)
        } else {
            ZStack {
                Color.black
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(vm.isAuthoritativeControlReady
                         ? (vm.selectedLanguage == .thai ? "กำลังเชื่อมต่อภาพตัวอย่าง…" : "Preview reconnecting…")
                         : (vm.selectedLanguage == .thai ? "กำลังรอกล้อง…" : "Waiting for camera…"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
    }

    private func viewportSize(in availableSize: CGSize) -> CGSize {
        guard let targetAspectRatio,
              targetAspectRatio.isFinite,
              targetAspectRatio > 0,
              availableSize.width > 0,
              availableSize.height > 0 else {
            return availableSize
        }

        let availableAspectRatio = availableSize.width / availableSize.height
        if availableAspectRatio > targetAspectRatio {
            return CGSize(
                width: availableSize.height * targetAspectRatio,
                height: availableSize.height
            )
        }
        return CGSize(
            width: availableSize.width,
            height: availableSize.width / targetAspectRatio
        )
    }
}

import SwiftUI
import CoreImage

// Shows the live camera preview streamed from the Mac.
struct PreviewMirrorView: View {
    @Environment(iPadViewModel.self) private var vm

    var body: some View {
        GeometryReader { geo in
            if let img = vm.latestPreviewImage {
                Image(img, scale: 1, label: Text("Preview"))
                    .interpolation(.high)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(x: vm.isMirrored ? -1 : 1, y: 1)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                ZStack {
                    Color.black
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(vm.selectedLanguage == .thai ? "กำลังรอกล้อง…" : "Waiting for camera…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

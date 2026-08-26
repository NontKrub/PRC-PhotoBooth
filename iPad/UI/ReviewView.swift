import SwiftUI

struct ReviewView: View {
    let photoIndex: Int
    @EnvironmentObject private var vm: iPadViewModel

    private var isThai: Bool { vm.selectedLanguage == .thai }

    var reviewImage: CGImage? {
        guard let data = vm.stateMachine.reviewImageData ?? vm.stateMachine.keptShots[photoIndex],
              let src = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 6) {
                    Text("How did it look?")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Photo \(photoIndex + 1) of \(vm.eventConfig.photoCount)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(0.5)
                }
                .padding(.top, 52)
                .padding(.bottom, 32)

                // Photo
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(white: 0.1))
                    if let img = reviewImage {
                        Image(img, scale: 1, label: Text("Shot"))
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(contentMode: .fit)
                .padding(.horizontal, 36)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)

                Spacer()

                // Buttons
                HStack(spacing: 16) {
                    // Retake — secondary
                    Button(action: { vm.customerRetake(photoIndex: photoIndex) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Retake")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 160, height: 60)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.reviewDecisionPending)

                    // Keep — primary
                    Button(action: { vm.customerKeep(photoIndex: photoIndex) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                        Text(LocalizedStringKey(photoIndex + 1 < vm.eventConfig.photoCount ? "Keep & next" : "Keep & finish"))
                                .font(.system(size: 17, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .frame(width: 200, height: 60)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.reviewDecisionPending)
                }
                .padding(.bottom, 56)
            }
        }
    }
}

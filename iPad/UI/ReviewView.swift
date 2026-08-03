import SwiftUI

struct ReviewView: View {
    let photoIndex: Int
    @Environment(iPadViewModel.self) private var vm

    private var isThai: Bool { vm.selectedLanguage == .thai }

    var thumbnail: CGImage? {
        guard let data = vm.stateMachine.keptShots[photoIndex],
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
                    Text(isThai ? "เป็นอย่างไรบ้าง?" : "How did it look?")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(isThai
                         ? "ภาพที่ \(photoIndex + 1) จาก \(vm.eventConfig.photoCount)"
                         : "Photo \(photoIndex + 1) of \(vm.eventConfig.photoCount)")
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
                    if let img = thumbnail {
                        Image(img, scale: 1, label: Text("Shot"))
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                }
                .frame(width: 380, height: 300)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)

                Spacer()

                // Buttons
                HStack(spacing: 16) {
                    // Retake — secondary
                    Button(action: { vm.customerRetake(photoIndex: photoIndex) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16, weight: .semibold))
                            Text(isThai ? "ถ่ายใหม่" : "Retake")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 160, height: 60)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    // Keep — primary
                    Button(action: { vm.customerKeep(photoIndex: photoIndex) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                        Text(isThai
                             ? (photoIndex + 1 < vm.eventConfig.photoCount ? "เก็บและถัดไป" : "เก็บและเสร็จสิ้น")
                             : (photoIndex + 1 < vm.eventConfig.photoCount ? "Keep & next" : "Keep & finish"))
                                .font(.system(size: 17, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .frame(width: 200, height: 60)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 56)
            }
        }
    }
}

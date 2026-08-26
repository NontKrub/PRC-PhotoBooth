import SwiftUI

// Combined Finish + QR screen
struct FinishAndQRView: View {
    let qrPayload: String
    @EnvironmentObject private var vm: iPadViewModel
    @State private var qrImage: CGImage?

    private var isThai: Bool { vm.selectedLanguage == .thai }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Soft ambient glow behind the QR
            RadialGradient(
                colors: [.white.opacity(0.06), .clear],
                center: .center, startRadius: 0, endRadius: 380
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Headline
                VStack(spacing: 6) {
                    Text("All done!")
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(-1)
                    Text("Scan to get your photos")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(0.3)
                }
                .padding(.bottom, 44)

                // QR — hero element
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white)
                        .frame(width: 280, height: 280)
                        .shadow(color: .white.opacity(0.15), radius: 40)
                    if let qr = qrImage {
                        Image(qr, scale: 1, label: Text("QR code"))
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 236, height: 236)
                    }
                }
                .padding(.bottom, 36)

                // Strip thumbnail — optional, compact
                if let strip = vm.stripThumbImage {
                    Image(strip, scale: 1, label: Text("Photo strip"))
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                        .padding(.bottom, 40)
                } else {
                    Spacer().frame(height: 40)
                }

                Spacer()

                // Next Session button
                Button(action: { vm.customerDone() }) {
                    Text("Next session")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 220, height: 58)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 56)
            }
        }
        .onAppear { qrImage = generateQRCode(from: qrPayload) }
    }
}

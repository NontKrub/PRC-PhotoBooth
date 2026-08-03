import SwiftUI

struct IdleView: View {
    @Environment(iPadViewModel.self) private var vm
    @State private var pulse = false

    var body: some View {
        ZStack {
            PreviewMirrorView().ignoresSafeArea()

            // Directional vignette — heavier at edges, clears the center
            RadialGradient(
                colors: [.clear, .black.opacity(0.55)],
                center: .center, startRadius: 180, endRadius: 620
            )
            .ignoresSafeArea()

            // Bottom legibility gradient
            VStack {
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Left logo + event name/subtext
                HStack(alignment: .center, spacing: 0) {
                    Image("SGPRCLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .padding(.leading, 52)
                        .padding(.trailing, 36)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(vm.eventConfig.eventName)
                            .font(.system(size: 56, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .tracking(-2)
                            .minimumScaleFactor(0.4)
                            .lineLimit(3)
                        Text(vm.selectedLanguage == .thai ? "จัดทำโดย nont" : "Created by nont")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .tracking(0.5)
                    }

                    Spacer()
                }

                Spacer()

                // Connection badge
                connectionBadge
                    .padding(.bottom, 44)

                // Tap indicator
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .strokeBorder(.white.opacity(pulse ? 0 : 0.2), lineWidth: 1)
                            .frame(width: pulse ? 80 : 50, height: pulse ? 80 : 50)
                            .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                        Circle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 50, height: 50)
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text(vm.selectedLanguage == .thai ? "แตะที่ใดก็ได้เพื่อเริ่ม" : "Tap anywhere to begin")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(0.5)
                }
                .padding(.bottom, 60)
            }
        }
        .onTapGesture {
            if case .connected = vm.multipeer.connectionState {
                vm.customerTappedToBegin()
            }
        }
        .onAppear { pulse = true }
    }

    var connectionBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(vm.multipeer.connectionState == .disconnected
                      ? Color(red: 1, green: 0.35, blue: 0.35)
                      : Color(red: 0.25, green: 0.88, blue: 0.5))
                .frame(width: 7, height: 7)
            Text(badgeLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }

    var badgeLabel: String {
        switch vm.multipeer.connectionState {
        case .connected(let name): return vm.selectedLanguage == .thai ? "เชื่อมต่อกับ \(name)" : "Connected to \(name)"
        case .connecting:          return vm.selectedLanguage == .thai ? "กำลังเชื่อมต่อ…" : "Connecting…"
        case .disconnected:        return vm.selectedLanguage == .thai ? "กำลังรอผู้ควบคุม" : "Waiting for operator"
        }
    }
}

import SwiftUI

struct StartView: View {
    @Environment(iPadViewModel.self) private var vm
    @State private var pressed = false

    private var isThai: Bool { vm.selectedLanguage == .thai }

    var body: some View {
        ZStack {
            PreviewMirrorView().ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Heading
                VStack(spacing: 10) {
                    Text("You're up!")
                        .font(.system(size: 60, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(-1)

                    // Event info pill
                    HStack(spacing: 10) {
                        Label("\(vm.eventConfig.photoCount) photos", systemImage: "photo.stack")
                        Rectangle()
                            .fill(.white.opacity(0.25))
                            .frame(width: 1, height: 12)
                        Label("\(vm.eventConfig.countdownSeconds)s countdown", systemImage: "timer")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))

                    if !vm.eventConfig.templateName.value(for: vm.selectedLanguage).isEmpty {
                        Text(vm.eventConfig.templateName.value(for: vm.selectedLanguage))
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(vm.eventConfig.selectedFilterID.displayName(for: vm.selectedLanguage))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.bottom, 52)

                // START button
                Button {
                    vm.customerTappedStart()
                } label: {
                    Text("START")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .tracking(4)
                        .foregroundStyle(.black)
                        .frame(width: 280, height: 80)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .scaleEffect(pressed ? 0.96 : 1.0)
                        .animation(.spring(duration: 0.2), value: pressed)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSessionRequestPending)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in pressed = true }
                        .onEnded { _ in pressed = false }
                )

                if vm.experienceCatalog != nil {
                    Button("Back to Options") {
                        vm.returnToExperienceSelection()
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 18)
                    .disabled(vm.isSessionRequestPending)
                }

                if vm.isSessionRequestPending {
                    ProgressView("Waiting for operator…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(.top, 18)
                } else if let error = vm.sessionRequestError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                }

                Spacer()
            }
        }
    }

}

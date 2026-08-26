import SwiftUI

struct CaptureRecoveryView: View {
    let photoIndex: Int
    let failure: CaptureFailureSummary
    @EnvironmentObject private var vm: iPadViewModel

    private var thai: Bool { vm.selectedLanguage == .thai }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: failure.reason == .cameraDisconnected ? "camera.slash" : "exclamationmark.triangle")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.orange)

            Text(thai ? "ไม่สามารถรับภาพที่ \(photoIndex + 1) จากกล้องได้" : "We couldn't receive Photo \(photoIndex + 1)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            Text(thai
                 ? "กล้องอาจถ่ายภาพแล้ว แต่ภาพยังไม่ถูกส่งมายังระบบ"
                 : "The camera may have taken the photo, but it did not transfer to the booth.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                if failure.canRetryReceive {
                    actionButton(
                        thai ? "ลองรับภาพอีกครั้ง" : "Try Receive Again",
                        systemImage: "arrow.clockwise",
                        primary: true
                    ) {
                        vm.customerRetryReceive(photoIndex: photoIndex)
                    }
                }

                actionButton(
                    thai ? "ถ่ายใหม่" : "Retake Photo",
                    systemImage: "camera",
                    primary: !failure.canRetryReceive
                ) {
                    vm.customerRetakeFailedCapture(photoIndex: photoIndex)
                }

                if failure.canUsePreviousPhoto {
                    actionButton(
                        thai ? "ใช้ภาพเดิม" : "Keep Previous Photo",
                        systemImage: "photo",
                        primary: false
                    ) {
                        vm.customerUsePreviousCapture(photoIndex: photoIndex)
                    }
                }

                if failure.canContinueSession {
                    actionButton(
                        thai ? "ถ่ายภาพถัดไปก่อน" : "Continue Session",
                        systemImage: "forward",
                        primary: false
                    ) {
                        vm.customerContinueAfterCaptureFailure(photoIndex: photoIndex)
                    }
                }
            }
            .frame(maxWidth: 420)
            .disabled(vm.recoveryActionPending)
        }
        .padding(32)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.plain)
        .foregroundStyle(primary ? .black : .white)
        .background(primary ? Color.white : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(primary ? 0 : 0.18), lineWidth: 1))
    }
}

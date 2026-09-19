import SwiftUI

struct CaptureRecoveryView: View {
    let photoIndex: Int
    let failure: CaptureFailureSummary
    @EnvironmentObject private var vm: iPadViewModel

    private var thai: Bool { vm.selectedLanguage == .thai }

    private func isEnabled(_ action: CaptureRecoveryAction) -> Bool {
        guard !vm.recoveryActionPending else { return false }
        guard vm.recoveryActionAwaitingReconciliation else { return true }
        return vm.recoveryActionToRetry == action
    }

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

            if vm.recoveryActionPending {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text(thai ? "กำลังประมวลผลตัวเลือกการกู้คืน…" : "Processing recovery choice…")
                }
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(thai ? "กำลังประมวลผลตัวเลือกการกู้คืน" : "Processing recovery choice")
            }

            if vm.recoveryActionAwaitingReconciliation {
                Text(thai
                     ? "บูธยังไม่ยืนยันตัวเลือกนี้ แตะปุ่มเดิมเพื่อลองใหม่อย่างปลอดภัย"
                     : "The booth did not confirm this choice. Tap the same button to retry safely.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                if failure.canRetryReceive {
                    actionButton(
                        thai ? "ลองรับภาพอีกครั้ง" : (vm.recoveryActionToRetry == .retryReceive(photoIndex: photoIndex) ? "Retry Receive" : "Try Receive Again"),
                        systemImage: "arrow.clockwise",
                        primary: true
                    ) {
                        vm.customerRetryReceive(photoIndex: photoIndex)
                    }
                    .disabled(!isEnabled(.retryReceive(photoIndex: photoIndex)))
                }

                actionButton(
                    thai ? "ถ่ายใหม่" : (vm.recoveryActionToRetry == .retake(photoIndex: photoIndex) ? "Retry Retake" : "Retake Photo"),
                    systemImage: "camera",
                    primary: !failure.canRetryReceive
                ) {
                    vm.customerRetakeFailedCapture(photoIndex: photoIndex)
                }
                .disabled(!isEnabled(.retake(photoIndex: photoIndex)))

                if failure.canUsePreviousPhoto {
                    actionButton(
                        thai ? "ใช้ภาพเดิม" : (vm.recoveryActionToRetry == .usePrevious(photoIndex: photoIndex) ? "Retry Keep Previous" : "Keep Previous Photo"),
                        systemImage: "photo",
                        primary: false
                    ) {
                        vm.customerUsePreviousCapture(photoIndex: photoIndex)
                    }
                    .disabled(!isEnabled(.usePrevious(photoIndex: photoIndex)))
                }

                if failure.canContinueSession {
                    actionButton(
                        thai ? "ถ่ายภาพถัดไปก่อน" : (vm.recoveryActionToRetry == .continueSession(photoIndex: photoIndex) ? "Retry Continue" : "Continue Session"),
                        systemImage: "forward",
                        primary: false
                    ) {
                        vm.customerContinueAfterCaptureFailure(photoIndex: photoIndex)
                    }
                    .disabled(!isEnabled(.continueSession(photoIndex: photoIndex)))
                }
            }
            .frame(maxWidth: 420)

            if let error = vm.sessionRequestError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
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

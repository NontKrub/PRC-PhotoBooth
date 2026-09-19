import SwiftUI

struct ReviewView: View {
    let photoIndex: Int
    @EnvironmentObject private var vm: iPadViewModel

    private var isThai: Bool { vm.selectedLanguage == .thai }
    private var retryAction: ReviewAction? { vm.reviewActionToRetry }

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
                    if let img = vm.reviewImage {
                        Image(img, scale: 1, label: Text("Shot"))
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    } else if vm.reviewImageDecodeFailed {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title)
                            Text(isThai ? "ไม่สามารถกู้คืนรูปภาพได้" : "Photo could not be restored.")
                                .font(.headline)
                            Text(isThai ? "กรุณาแจ้งผู้ควบคุมให้ลองอีกครั้ง" : "Ask the operator to try again.")
                                .font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            isThai ? "ไม่สามารถกู้คืนรูปภาพได้ กรุณาแจ้งผู้ควบคุมให้ลองอีกครั้ง" :
                                "Photo could not be restored. Ask the operator to try again."
                        )
                    } else {
                        VStack(spacing: 14) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.15)
                            Text(isThai ? "กำลังกู้คืนรูปภาพ…" : "Restoring photo…")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.78))
                            if let detail = vm.assetRecoveryStatus.detail(for: vm.selectedLanguage) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.65))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            isThai ? "กำลังกู้คืนรูปภาพ" : "Restoring photo"
                        )
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
                            Text(isThai
                                 ? (retryAction == .retake ? "ลองถ่ายใหม่อีกครั้ง" : "ถ่ายใหม่")
                                 : (retryAction == .retake ? "Retry Retake" : "Retake"))
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 160, height: 60)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        !vm.isReviewMediaReady
                            || vm.reviewDecisionPending
                            || (vm.reviewDecisionAwaitingReconciliation && retryAction != .retake)
                    )

                    // Keep — primary
                    Button(action: { vm.customerKeep(photoIndex: photoIndex) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                        Text(isThai
                             ? (retryAction == .keep
                                ? "ลองยืนยันอีกครั้ง"
                                : photoIndex + 1 < vm.eventConfig.photoCount ? "เก็บและไปต่อ" : "เก็บและเสร็จสิ้น")
                             : (retryAction == .keep
                                ? "Retry Keep"
                                : photoIndex + 1 < vm.eventConfig.photoCount ? "Keep & next" : "Keep & finish"))
                                .font(.system(size: 17, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .frame(width: 200, height: 60)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        !vm.isReviewMediaReady
                            || vm.reviewDecisionPending
                            || (vm.reviewDecisionAwaitingReconciliation && retryAction != .keep)
                    )
                }
                .padding(.bottom, 56)

                if vm.reviewDecisionPending {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Saving your choice…")
                            .font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Saving your choice")
                    .padding(.bottom, 20)
                } else if vm.reviewDecisionAwaitingReconciliation {
                    Text(isThai
                         ? "บูธยังไม่ยืนยันตัวเลือกนี้ แตะตัวเลือกเดิมเพื่อลองใหม่อย่างปลอดภัย"
                         : "The booth did not confirm that choice. Tap the same choice to retry safely.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .padding(.bottom, 20)
                }

                if let error = vm.sessionRequestError, !vm.reviewDecisionAwaitingReconciliation {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                        .padding(.bottom, 20)
                }
            }
        }
    }
}

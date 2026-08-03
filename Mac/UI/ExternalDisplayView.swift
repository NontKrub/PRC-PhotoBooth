import SwiftUI
import AppKit

// Customer-facing viewer shown on an external monitor — a Mac-native stand-in for the iPad
// screen when no iPad is used. Driven directly by BoothCoordinator + SessionStateMachine
// (same process as the operator console, so no MultipeerConnectivity round-trip is needed).
struct ExternalDisplayView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(SessionStateMachine.self) private var sm
    @State private var qrImage: CGImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch sm.phase {
            case .idle:
                idleContent
            case .selectingExperience:
                ExternalExperienceSelectionView()
            case .readyToStart:
                readyContent
            case .countdown(let idx, let secs):
                countdownContent(photoIndex: idx, secondsRemaining: secs)
            case .captured, .processing:
                processingContent
            case .review(let idx):
                reviewContent(photoIndex: idx)
            case .finished(let qr):
                finishedContent(qrPayload: qr)
            }
        }
    }

    // MARK: - Idle / ready

    private var idleContent: some View {
        ZStack {
            cameraPreview
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 180, endRadius: 620)
                .ignoresSafeArea()

            VStack {
                HStack(spacing: 24) {
                    Image("SGPRCLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Text(coordinator.activeEvent?.name ?? "PRC PhotoBooth")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(60)

                Spacer()

                Text(startHintText)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 70)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { attemptStart() }
    }

    private var startHintText: String {
        coordinator.activeEvent == nil ? "No active event — set one up on the operator Mac" : "Click anywhere to begin"
    }

    private func attemptStart() {
        guard sm.phase == .idle, coordinator.activeEvent != nil else { return }
        if coordinator.externalSelectionRequired {
            coordinator.beginExternalExperienceSelection()
        } else {
            coordinator.startSession()
        }
    }

    private var readyContent: some View {
        VStack(spacing: 24) {
            Text("Ready?")
                .font(.system(size: 52, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text(sm.config.templateName.value(for: sm.config.customerLanguage))
                .font(.title2)
                .foregroundStyle(.white.opacity(0.75))
            Text("\(sm.config.photoCount) photos · \(filterName(sm.config.selectedFilterID))")
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 16) {
                Button("Back to Options") { coordinator.beginExternalExperienceSelection() }
                    .buttonStyle(.bordered)
                Button("Start") {
                    coordinator.startSession(selection: coordinator.externalSelection.selection)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func filterName(_ filter: PhotoFilterID) -> String {
        switch filter {
        case .original: return "Original"
        case .monochrome: return "Monochrome"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .highContrast: return "High Contrast"
        case .soft: return "Soft"
        case .vintage: return "Vintage"
        }
    }

    // MARK: - Countdown

    private func countdownContent(photoIndex: Int, secondsRemaining: Int) -> some View {
        ZStack {
            cameraPreview
            Color.black.opacity(0.2).ignoresSafeArea()

            VStack {
                Spacer()
                if let prompt = coordinator.currentSessionPresentation?.prompts.first(where: { $0.photoIndex == photoIndex }) {
                    HStack(spacing: 14) {
                        if let data = prompt.imageData,
                           let source = CGImageSourceCreateWithData(data as CFData, nil),
                           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                            Image(nsImage: flipSafeImage(image))
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 180, maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(prompt.title)
                                .font(.title2.bold())
                                .lineLimit(3)
                            if !prompt.subtitle.isEmpty {
                                Text(prompt.subtitle)
                                    .font(.body)
                                    .lineLimit(3)
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
                }
                Spacer()
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.15), lineWidth: 10).frame(width: 320, height: 320)
                    Circle()
                        .trim(from: 0, to: countdownProgress(secondsRemaining))
                        .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .frame(width: 320, height: 320)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: secondsRemaining)
                    Text("\(secondsRemaining)")
                        .font(.system(size: 180, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.spring(duration: 0.25), value: secondsRemaining)
                }
                Spacer()
                Text("Photo \(photoIndex + 1) of \(sm.config.photoCount)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 70)
            }
        }
    }

    private func countdownProgress(_ secondsRemaining: Int) -> CGFloat {
        guard sm.config.countdownSeconds > 0 else { return 1 }
        return CGFloat(secondsRemaining) / CGFloat(sm.config.countdownSeconds)
    }

    // MARK: - Processing

    private var processingContent: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(2).tint(.white)
            Text("Processing…").foregroundStyle(.white).font(.title2)
        }
    }

    // MARK: - Review

    private func reviewContent(photoIndex: Int) -> some View {
        VStack(spacing: 36) {
            Text("How did it look?")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.1))
                if let img = coordinator.currentFilteredReviewImages[photoIndex]
                    ?? coordinator.capture.capturedStills[photoIndex] {
                    Image(nsImage: flipSafeImage(img))
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            }
            .frame(width: 460, height: 360)
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)

            HStack(spacing: 24) {
                Button(action: { coordinator.handleReviewDecision(photoIndex: photoIndex, action: .retake) }) {
                    Label("Retake", systemImage: "arrow.counterclockwise").frame(width: 170, height: 56)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)

                Button(action: { coordinator.handleReviewDecision(photoIndex: photoIndex, action: .keep) }) {
                    Label(photoIndex + 1 < sm.config.photoCount ? "Keep & next" : "Keep & finish", systemImage: "checkmark")
                        .frame(width: 230, height: 56)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Finished

    private func finishedContent(qrPayload: String) -> some View {
        VStack(spacing: 28) {
            Text("All done!")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("Scan to get your photos")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(Color.white).frame(width: 260, height: 260)
                if let qr = qrImage {
                    Image(nsImage: flipSafeImage(qr))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                }
            }

            Button("Next session") { coordinator.operatorOverride(.cancelSession) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 12)
        }
        .task(id: qrPayload) { qrImage = generateQRCode(from: qrPayload) }
    }

    // MARK: - Shared

    private var cameraPreview: some View {
        Group {
#if DEBUG
            if coordinator.capture.demoMode, let image = coordinator.capture.demoPreviewImage {
                Image(nsImage: flipSafeImage(image))
                    .resizable()
                    .scaledToFill()
            } else if coordinator.capture.isRunning, let session = coordinator.capture.camera.captureSession {
                CameraPreviewView(captureSession: session, isMirrored: coordinator.capture.camera.isMirrored)
            } else {
                Color.black
            }
#else
            if coordinator.capture.isRunning, let session = coordinator.capture.camera.captureSession {
                CameraPreviewView(captureSession: session, isMirrored: coordinator.capture.camera.isMirrored)
            } else {
                Color.black
            }
#endif
        }
        .ignoresSafeArea()
    }

    // NSImage(cgImage:size:) re-flips on macOS (see CLAUDE.md); NSBitmapImageRep preserves raw pixel layout.
    private func flipSafeImage(_ cg: CGImage) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cg)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

import SwiftUI

struct CountdownView: View {
    let photoIndex: Int
    let secondsRemaining: Int
    @Environment(iPadViewModel.self) private var vm

    var body: some View {
        ZStack {
            PreviewMirrorView().ignoresSafeArea()
            Color.black.opacity(0.25).ignoresSafeArea()

            VStack(spacing: 0) {
                // Photo strip progress at top
                photoProgress
                    .padding(.top, 52)

                Spacer()

                // Countdown ring + number
                ZStack {
                    // Background track
                    Circle()
                        .strokeBorder(.white.opacity(0.1), lineWidth: 8)
                        .frame(width: 260, height: 260)

                    // Progress arc
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AngularGradient(
                                colors: [.white.opacity(0.4), .white],
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .frame(width: 260, height: 260)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: secondsRemaining)

                    // Number
                    Text("\(secondsRemaining)")
                        .font(.system(size: 148, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.spring(duration: 0.25), value: secondsRemaining)
                }

                Spacer()

                // Caption
                Text("Photo \(photoIndex + 1) of \(vm.eventConfig.photoCount)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(1)
                    .padding(.bottom, 60)
            }
        }
    }

    var progress: CGFloat {
        guard vm.eventConfig.countdownSeconds > 0 else { return 1 }
        return CGFloat(secondsRemaining) / CGFloat(vm.eventConfig.countdownSeconds)
    }

    var photoProgress: some View {
        HStack(spacing: 8) {
            ForEach(0..<vm.eventConfig.photoCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < photoIndex ? .white : (i == photoIndex ? .white : .white.opacity(0.2)))
                    .frame(width: i == photoIndex ? 28 : 18, height: 4)
                    .animation(.spring(duration: 0.3), value: photoIndex)
            }
        }
    }
}

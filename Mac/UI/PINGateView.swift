import SwiftUI
import LocalAuthentication

// Modal PIN entry / setup sheet.
// Mode: .setup (first time, creates PIN) or .verify (unlock).
struct PINGateView: View {
    enum Mode { case setup, verify }

    let mode: Mode
    var onSuccess: () -> Void
    var onCancel: (() -> Void)? = nil

    @State private var digits: [String] = []
    @State private var confirmDigits: [String] = []
    @State private var phase: Phase = .enter
    @State private var shake = false
    @State private var errorMsg: String? = nil
    @State private var deviceOwnerAuthenticationAvailable = false
    @FocusState private var focused: Bool
    @Environment(\.locale) private var locale

    private enum Phase { case enter, confirm }

    var body: some View {
        VStack(spacing: 28) {
            // Title
            VStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Dots indicator
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < currentDigits.count ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(ShakeEffect(trigger: shake))

            if let err = errorMsg {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            // Number pad
            numPad

            if mode == .verify && deviceOwnerAuthenticationAvailable {
                Button(action: authenticateWithDeviceOwner) {
                    Label("Use Touch ID or Mac Password", systemImage: "touchid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if let cancel = onCancel {
                Button("Cancel", role: .cancel, action: cancel)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: 320)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            let ch = press.characters
            if let digit = ch.first, digit.isNumber {
                tap(String(digit))
                return .handled
            }
            if press.key == .delete || ch == "\u{7F}" || ch == "\u{8}" {
                tap("⌫")
                return .handled
            }
            return .ignored
        }
        .onAppear {
            focused = true
            refreshDeviceOwnerAuthenticationAvailability()
        }
    }

    // MARK: - Computed

    var currentDigits: [String] {
        phase == .confirm ? confirmDigits : digits
    }

    var title: String {
        switch mode {
        case .setup:   return operatorString(phase == .enter ? "Create Admin PIN" : "Confirm PIN", locale: locale)
        case .verify:  return operatorString("Admin Access", locale: locale)
        }
    }

    var subtitle: String {
        switch mode {
        case .setup:   return operatorString(phase == .enter ? "Choose a 4-digit PIN to protect operator settings." : "Enter the same PIN again.", locale: locale)
        case .verify:  return operatorString("Enter your 4-digit PIN to continue.", locale: locale)
        }
    }

    // MARK: - Numpad

    var numPad: some View {
        let keys = [["1","2","3"],["4","5","6"],["7","8","9"],["","0","⌫"]]
        return VStack(spacing: 12) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 64, height: 48)
                        } else {
                            Button(action: { tap(key) }) {
                                Text(key)
                                    .font(.title3.bold())
                                    .frame(width: 64, height: 48)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Logic

    private func tap(_ key: String) {
        errorMsg = nil
        if key == "⌫" {
            if phase == .confirm { if !confirmDigits.isEmpty { confirmDigits.removeLast() } }
            else { if !digits.isEmpty { digits.removeLast() } }
            return
        }
        if phase == .confirm {
            guard confirmDigits.count < 4 else { return }
            confirmDigits.append(key)
            if confirmDigits.count == 4 { commitConfirm() }
        } else {
            guard digits.count < 4 else { return }
            digits.append(key)
            if digits.count == 4 { commitEnter() }
        }
    }

    private func commitEnter() {
        switch mode {
        case .setup:
            phase = .confirm
        case .verify:
            if verifyPIN(digits.joined()) {
                onSuccess()
            } else {
                triggerError(operatorString("Incorrect PIN. Try again.", locale: locale))
            }
        }
    }

    private func commitConfirm() {
        if confirmDigits.joined() == digits.joined() {
            setPIN(digits.joined())
            onSuccess()
        } else {
            triggerError(operatorString("PINs don't match. Start over.", locale: locale))
            digits = []; confirmDigits = []; phase = .enter
        }
    }

    private func triggerError(_ msg: String) {
        errorMsg = msg
        shake = false
        withAnimation(.spring(duration: 0.4)) { shake = true }
        Task { try? await Task.sleep(for: .milliseconds(500)); shake = false }
        digits = []; confirmDigits = []
    }

    private func refreshDeviceOwnerAuthenticationAvailability() {
        let context = LAContext()
        deviceOwnerAuthenticationAvailable = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    private func authenticateWithDeviceOwner() {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            deviceOwnerAuthenticationAvailable = false
            triggerError(operatorString("This Mac can't verify its owner right now. Try your PIN.", locale: locale))
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: operatorString("Unlock PRC PhotoBooth administrator settings with Touch ID or your Mac password.", locale: locale)
        ) { success, error in
            Task { @MainActor in
                if success {
                    onSuccess()
                } else {
                    let nsError = error as? LAError
                    if nsError?.code == .userCancel || nsError?.code == .appCancel {
                        return
                    }
                    triggerError("Could not verify Touch ID or your Mac password. Try again or enter your PIN.")
                }
            }
        }
    }
}

// MARK: - Shake modifier

struct ShakeEffect: GeometryEffect {
    var trigger: Bool
    var animatableData: CGFloat = 0

    init(trigger: Bool) {
        self.trigger = trigger
        animatableData = trigger ? 1 : 0
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = sin(animatableData * .pi * 4) * 8
        return ProjectionTransform(CGAffineTransform(translationX: t, y: 0))
    }
}

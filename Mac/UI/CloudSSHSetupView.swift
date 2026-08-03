import SwiftUI
import AppKit

struct CloudSSHSetupView: View {
    @Bindable var setup: CloudSSHSetupService
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: CloudSSHConfiguration

    init(setup: CloudSSHSetupService) {
        self.setup = setup
        _configuration = State(initialValue: setup.configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.icloud.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cloud SSH setup")
                        .font(.title2.bold())
                    Text("Prepare this Mac to back up completed photo sessions through Cloudflare Access.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Connection details") {
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow {
                        Text("SSH alias")
                        TextField("nont-srv1", text: $configuration.alias)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                    }
                    GridRow {
                        Text("Server user")
                        TextField("nont", text: $configuration.username)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                    }
                    GridRow {
                        Text("Tunnel hostname")
                        TextField("ssh.nakrub.me", text: $configuration.tunnelHostname)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                    }
                }
                .padding(4)
            }

            GroupBox("Readiness") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(setup.requirements) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: imageName(for: item.status))
                                .foregroundStyle(color(for: item.status))
                                .frame(width: 15)
                            Text(item.id.title).fontWeight(.medium)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }

            if !setup.publicKey.isEmpty {
                GroupBox("Authorize this Mac on the server") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add this public key to the server user’s ~/.ssh/authorized_keys, then run the connection test again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(setup.publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Button("Copy Public Key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(setup.publicKey, forType: .string)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(4)
                }
            }

            if !setup.progressMessage.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(setup.progressMessage)
                        .font(.callout)
                        .foregroundStyle(setup.state == .complete ? .green : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !setup.lastOutput.isEmpty, setup.state != .complete {
                        Text(setup.lastOutput)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if hasAliasConflict {
                Button("Use ‘prc-\(configuration.alias)’ Instead") {
                    configuration.alias = "prc-\(configuration.alias)"
                    setup.configuration = configuration
                    setup.progressMessage = "Using a separate PhotoBooth SSH alias preserves your existing ‘\(configuration.alias.dropFirst(4))’ entry. Add the public key above, then continue setup."
                    setup.lastOutput = ""
                    setup.refreshChecks()
                }
                .buttonStyle(.bordered)
                .help("Keeps your existing SSH host unchanged and creates a dedicated PhotoBooth alias.")
            }

            HStack {
                Button {
                    if setup.state != .complete { setup.skip() }
                    dismiss()
                } label: {
                    Text(LocalizedStringKey(setup.state == .complete ? "Close" : "Skip for Now"))
                }
                .disabled(setup.isWorking)

                Spacer()

                Button("Refresh Checks") {
                    setup.configuration = configuration
                    setup.refreshChecks()
                }
                .disabled(setup.isWorking)

                Button {
                    setup.configuration = configuration
                    Task { await setup.prepareAuthenticateAndTest() }
                } label: {
                    Text(LocalizedStringKey(setup.state == .complete ? "Test Connection Again" : "Set Up & Test"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(setup.isWorking)
            }
        }
        .padding(24)
        .frame(width: 690)
        .interactiveDismissDisabled(setup.shouldPresentFirstRun)
        .onAppear {
            configuration = setup.configuration
            setup.reopen()
        }
    }

    private func imageName(for status: CloudSSHRequirement.Status) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .needsSetup, .failed: "exclamationmark.triangle.fill"
        case .unknown: "circle.dashed"
        }
    }

    private func color(for status: CloudSSHRequirement.Status) -> Color {
        switch status {
        case .ready: .green
        case .needsSetup, .failed: .orange
        case .unknown: .secondary
        }
    }

    private var hasAliasConflict: Bool {
        setup.progressMessage.contains("already exists outside PRC PhotoBooth’s managed configuration")
    }
}

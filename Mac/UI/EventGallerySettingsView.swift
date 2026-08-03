import SwiftUI
import AppKit

struct EventGallerySettingsView: View {
    @Binding var configuration: EventGalleryConfiguration
    let serverURL: String
    @State private var confirmTokenRegeneration = false

    init(configuration: Binding<EventGalleryConfiguration>, serverURL: String = "") {
        _configuration = configuration
        self.serverURL = serverURL
    }

    var body: some View {
        Section("Event Gallery") {
            Picker("Mode", selection: $configuration.mode) {
                Text("Disabled").tag(EventGalleryMode.disabled)
                Text("Approval required").tag(EventGalleryMode.approvalRequired)
                Text("Automatic").tag(EventGalleryMode.automatic)
            }
            TextField("Gallery title (English)", text: $configuration.title.english)
            TextField("Gallery title (Thai)", text: $configuration.title.thai)
            Picker("Gallery language", selection: $configuration.language) {
                Text("English").tag(CustomerLanguage.english)
                Text("ไทย").tag(CustomerLanguage.thai)
            }
            Toggle("Show GIF links", isOn: $configuration.showGIFLinks)
            if configuration.mode != .disabled {
                Text("Token: \(configuration.eventToken)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("Local network only. Regenerating the token invalidates old gallery links.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let url = galleryURL {
                    Text(url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        }
                        Button("Open Gallery") {
                            if let destination = URL(string: url) { NSWorkspace.shared.open(destination) }
                        }
                        Button("Regenerate Token…") { confirmTokenRegeneration = true }
                    }
                } else {
                    Text("Gallery URL unavailable: no LAN address")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Regenerate Token…") { confirmTokenRegeneration = true }
                }
            }
        }
        .alert("Regenerate gallery token?", isPresented: $confirmTokenRegeneration) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                configuration.eventToken = UUID().uuidString
            }
        } message: {
            Text("Old gallery links will stop working after you save this event experience.")
        }
    }

    private var galleryURL: String? {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty else { return nil }
        return "\(base)/e/\(configuration.eventToken)/"
    }
}

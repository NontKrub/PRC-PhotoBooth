import SwiftUI
import UniformTypeIdentifiers

struct TemplateDetailView: View {
    @Binding var template: EventTemplateDefinition
    let frame: CGImage?
    let foregroundOverlay: CGImage?
    let onImportFrame: (URL) -> Void
    let onImportForegroundOverlay: (URL) -> Void
    let onRemoveForegroundOverlay: () -> Void
    let onImportPromptImage: (Int, URL) -> Void
    @State private var showingAssetImporter = false
    @State private var assetImportDestination: AssetImportDestination?
    @State private var showingSlotEditor = false

    private enum AssetImportDestination {
        case frame
        case foregroundOverlay
    }

    var body: some View {
        Form {
            Section("Names") {
                TextField("English name", text: $template.name.english)
                TextField("Thai name", text: $template.name.thai)
            }
            Section("Layout") {
                Toggle("Enabled", isOn: $template.isEnabled)
                Stepper("Photos: \(template.photoCount)", value: $template.photoCount, in: 1...8)
                HStack {
                    Text("Canvas")
                    TextField("Width", value: $template.canvasWidth, format: .number)
                    Text("×")
                    TextField("Height", value: $template.canvasHeight, format: .number)
                }
            }
            Section("Frame") {
                if let frameFileName = template.frameFileName {
                    Text(frameFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No frame imported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Import / Replace Frame PNG…") {
                    assetImportDestination = .frame
                    showingAssetImporter = true
                }
            }
            Section("Foreground Overlay") {
                Text(template.foregroundOverlayFileName ?? "No foreground overlay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Import / Replace Foreground PNG…") {
                    assetImportDestination = .foregroundOverlay
                    showingAssetImporter = true
                }
                if template.foregroundOverlayFileName != nil {
                    Button("Remove Foreground Overlay", role: .destructive, action: onRemoveForegroundOverlay)
                }
            }
            Section("Canvas Elements") {
                Text("\(template.slots.count) photo slots · \(template.qrCodeElements.count) QR codes")
                    .foregroundStyle(.secondary)
                Button("Edit Layout…") { showingSlotEditor = true }
            }
            Section("Pose Prompts") {
                PosePromptEditorView(template: $template, onImportImage: onImportPromptImage)
            }
        }
        .fileImporter(
            isPresented: $showingAssetImporter,
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false
        ) { result in
            defer { assetImportDestination = nil }
            guard case .success(let urls) = result,
                  let url = urls.first,
                  let assetImportDestination else { return }
            switch assetImportDestination {
            case .frame:
                onImportFrame(url)
            case .foregroundOverlay:
                onImportForegroundOverlay(url)
            }
        }
        .sheet(isPresented: $showingSlotEditor) {
            TemplateFrameSlotEditor(
                slots: $template.slots,
                qrCodeElements: $template.qrCodeElements,
                canvasWidth: template.canvasWidth,
                canvasHeight: template.canvasHeight,
                photoCount: template.photoCount,
                frame: frame,
                foregroundOverlay: foregroundOverlay
            )
        }
    }
}

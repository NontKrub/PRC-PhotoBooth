import SwiftUI
import UniformTypeIdentifiers

struct TemplateDetailView: View {
    @Binding var template: EventTemplateDefinition
    @Binding var frame: CGImage?
    let isFrameConfigured: Bool
    let isFrameLoading: Bool
    let frameErrorMessage: String?
    let onImportFrame: (URL) -> Void
    let onImportPromptImage: (Int, URL) -> Void
    @State private var showingImporter = false
    @State private var showingSlotEditor = false

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
                Button("Import / Replace Frame PNG…") { showingImporter = true }
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
            isPresented: $showingImporter,
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            onImportFrame(url)
        }
        .sheet(isPresented: $showingSlotEditor) {
            TemplateFrameSlotEditor(
                slots: $template.slots,
                qrCodeElements: $template.qrCodeElements,
                canvasWidth: template.canvasWidth,
                canvasHeight: template.canvasHeight,
                photoCount: template.photoCount,
                frame: $frame,
                isFrameConfigured: isFrameConfigured,
                isFrameLoading: isFrameLoading,
                frameErrorMessage: frameErrorMessage
            )
        }
    }
}

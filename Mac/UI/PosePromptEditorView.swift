import SwiftUI

struct PosePromptEditorView: View {
    @Binding var template: EventTemplateDefinition
    let onImportImage: (Int, URL) -> Void
    @State private var importingPhotoIndex: Int?

    var body: some View {
        ForEach(0..<template.photoCount, id: \.self) { index in
            let promptIndex = template.posePrompts.firstIndex(where: { $0.photoIndex == index })
            HStack(alignment: .top) {
                Toggle("Photo \(index + 1)", isOn: Binding(
                    get: { promptIndex.map { template.posePrompts[$0].isEnabled } ?? false },
                    set: { enabled in
                        if let promptIndex {
                            template.posePrompts[promptIndex].isEnabled = enabled
                        } else if enabled {
                            template.posePrompts.append(PosePromptDefinition(photoIndex: index))
                        }
                    }
                ))
                if let promptIndex {
                    VStack {
                        TextField("English prompt", text: $template.posePrompts[promptIndex].title.english)
                        TextField("Thai prompt", text: $template.posePrompts[promptIndex].title.thai)
                        TextField("English subtitle", text: $template.posePrompts[promptIndex].subtitle.english)
                        TextField("Thai subtitle", text: $template.posePrompts[promptIndex].subtitle.thai)
                        HStack {
                            Text(template.posePrompts[promptIndex].imageFileName ?? "No prompt image")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Import Image…") { importingPhotoIndex = index }
                            if template.posePrompts[promptIndex].imageFileName != nil {
                                Button("Remove") { template.posePrompts[promptIndex].imageFileName = nil }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: template.photoCount) { _, count in
            template.posePrompts.removeAll { $0.photoIndex >= count }
        }
        .fileImporter(
            isPresented: Binding(
                get: { importingPhotoIndex != nil },
                set: { if !$0 { importingPhotoIndex = nil } }
            ),
            allowedContentTypes: [.png, .jpeg, .heic],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first,
                  let index = importingPhotoIndex else { return }
            importingPhotoIndex = nil
            onImportImage(index, url)
        }
    }
}

import SwiftUI
import ImageIO

struct EventExperienceEditorView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let event: BoothEvent

    @State private var document = EventExperienceDocument(
        id: "loading",
        eventID: "loading",
        defaultTemplateID: "loading",
        templates: [EventTemplateDefinition(
            id: "loading",
            name: LocalizedText(english: "Loading"),
            photoCount: 1,
            canvasWidth: 400,
            canvasHeight: 600,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        )],
        gallery: EventGalleryConfiguration()
    )
    @State private var selectedTemplateID: String?
    @State private var previews: [String: CGImage] = [:]
    @State private var frames: [String: CGImage] = [:]
    @State private var loadingFrameIDs = Set<String>()
    @State private var frameErrors: [String: String] = [:]
    @State private var isLoading = true
    @State private var isLoadingPreviews = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var editingTemplateID: String?
    @State private var previewLoadID = UUID()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading experience…")
            } else {
                Form {
                    if isLoadingPreviews {
                        ProgressView("Loading previews…")
                    }
                    TemplateListView(
                        templates: $document.templates,
                        defaultTemplateID: $document.defaultTemplateID,
                        previews: previews,
                        onAdd: addTemplate,
                        onEdit: { editingTemplateID = $0 },
                        onDuplicate: duplicate,
                        onDelete: delete,
                        onMove: move
                    )

                    Section("Guest Selection") {
                        Toggle("Allow template selection", isOn: $document.guestTemplateSelectionEnabled)
                        Toggle("Allow filter selection", isOn: $document.guestFilterSelectionEnabled)
                        Toggle("Allow language selection", isOn: $document.guestLanguageSelectionEnabled)
                    }

                    Section("Filters") {
                        ForEach(PhotoFilterID.allCases) { filter in
                            Toggle(filter.displayName(for: operatorLanguage), isOn: filterBinding(filter))
                                .disabled(filter == .original)
                        }
                        Picker("Default filter", selection: $document.defaultFilterID) {
                            ForEach(document.allowedFilterIDs) { filter in
                                Text(filter.displayName(for: operatorLanguage)).tag(filter)
                            }
                        }
                    }

                    Section("Language") {
                        Picker("Default customer language", selection: $document.defaultCustomerLanguage) {
                            Text("English").tag(CustomerLanguage.english)
                            Text("ไทย").tag(CustomerLanguage.thai)
                        }
                    }

                    EventGallerySettingsView(configuration: $document.gallery, serverURL: coordinator.serverURL)

                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Guest Experience")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { save() } label: {
                    Text(LocalizedStringKey(isSaving ? "Saving…" : "Save"))
                }
                    .disabled(isLoading || isSaving)
            }
        }
        .task(id: event.id) {
            do {
                document = try await coordinator.loadExperienceDocument(for: event)
                selectedTemplateID = document.defaultTemplateID
                isLoading = false
                previewLoadID = UUID()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
        .task(id: previewLoadID) {
            guard !isLoading else { return }
            isLoadingPreviews = true
            defer { isLoadingPreviews = false }
            do {
                try await loadPreviews()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: document.templates) { oldTemplates, newTemplates in
            let templateIDs = Set(newTemplates.map(\.id))
            previews = previews.filter { templateIDs.contains($0.key) }
            for template in newTemplates {
                if oldTemplates.first(where: { $0.id == template.id }) != template {
                    previews[template.id] = nil
                }
            }
        }
        .sheet(item: Binding(
            get: { editingTemplateID.flatMap { id in document.templates.firstIndex(where: { $0.id == id }).map { document.templates[$0] } } },
            set: { editingTemplateID = $0?.id }
        )) { template in
            if let index = document.templates.firstIndex(where: { $0.id == template.id }) {
                NavigationStack {
                    TemplateDetailView(
                        template: $document.templates[index],
                        frame: Binding(
                            get: { frames[template.id] },
                            set: { image in
                                if let image { frames[template.id] = image }
                                else { frames.removeValue(forKey: template.id) }
                            }
                        ),
                        isFrameConfigured: template.frameFileName != nil,
                        isFrameLoading: loadingFrameIDs.contains(template.id),
                        frameErrorMessage: frameErrors[template.id]
                    ) { url in
                        importFrame(url, templateID: template.id)
                    } onImportPromptImage: { photoIndex, url in
                        importPromptImage(url, templateID: template.id, photoIndex: photoIndex)
                    }
                    .navigationTitle(template.name.value(for: operatorLanguage))
                }
                .frame(minWidth: 560, minHeight: 620)
                .task { await loadFrame(templateID: template.id) }
            }
        }
    }

    private func filterBinding(_ filter: PhotoFilterID) -> Binding<Bool> {
        Binding(
            get: { document.allowedFilterIDs.contains(filter) },
            set: { enabled in
                if enabled {
                    document.allowedFilterIDs = PhotoFilterID.allCases.filter {
                        $0 == filter || document.allowedFilterIDs.contains($0)
                    }
                } else {
                    document.allowedFilterIDs.removeAll { $0 == filter }
                    if document.defaultFilterID == filter { document.defaultFilterID = .original }
                }
            }
        )
    }

    private func duplicate(_ id: String) {
        guard document.templates.count < 8,
              let source = document.templates.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID().uuidString
        copy.name.english += " Copy"
        copy.name.thai += " สำเนา"
        copy.sortOrder = document.templates.count
        copy.createdAt = Date()
        copy.updatedAt = Date()
        let promptIDMap = Dictionary(uniqueKeysWithValues: copy.posePrompts.map { ($0.id, UUID().uuidString) })
        copy.posePrompts = copy.posePrompts.map {
            var prompt = $0
            let oldID = prompt.id
            prompt.id = promptIDMap[oldID] ?? UUID().uuidString
            if prompt.imageFileName != nil {
                prompt.imageFileName = "\(prompt.id).jpg"
            }
            return prompt
        }
        document.templates.append(copy)
        Task {
            try? await coordinator.experienceStore.duplicateTemplateAssets(
                eventID: event.id,
                sourceTemplateID: source.id,
                destinationTemplateID: copy.id,
                promptIDMap: promptIDMap
            )
        }
    }

    private func addTemplate() {
        guard document.templates.count < 8,
              let source = document.templates.first(where: { $0.id == document.defaultTemplateID }) ?? document.templates.first else { return }
        let template = EventTemplateDefinition(
            name: LocalizedText(english: "New Template", thai: "เทมเพลตใหม่"),
            sortOrder: document.templates.count,
            photoCount: source.photoCount,
            canvasWidth: source.canvasWidth,
            canvasHeight: source.canvasHeight,
            slots: source.slots.map {
                var slot = $0
                slot.id = UUID().uuidString
                return slot
            }
        )
        document.templates.append(template)
        editingTemplateID = template.id
    }

    private func delete(_ id: String) {
        guard document.templates.count > 1,
              let template = document.templates.first(where: { $0.id == id }),
              template.id != document.defaultTemplateID || document.templates.contains(where: { $0.id != id && $0.isEnabled }) else { return }
        document.templates.removeAll { $0.id == id }
        if document.defaultTemplateID == id {
            document.defaultTemplateID = document.templates.first(where: \.isEnabled)?.id ?? document.templates[0].id
        }
    }

    private func move(_ id: String, _ delta: Int) {
        guard let index = document.templates.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard document.templates.indices.contains(target) else { return }
        document.templates.swapAt(index, target)
        for index in document.templates.indices { document.templates[index].sortOrder = index }
    }

    private func importFrame(_ url: URL, templateID: String) {
        Task {
            do {
                let imported = try await coordinator.experienceStore.importTemplateFrame(
                    eventID: event.id,
                    templateID: templateID,
                    sourceURL: url
                )
                guard let index = document.templates.firstIndex(where: { $0.id == templateID }) else { return }
                document.templates[index].frameFileName = imported.fileName
                document.templates[index].updatedAt = Date()
                let data = try Data(contentsOf: imported.url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw EventExperienceError.importFailed("Could not decode imported frame.")
                }
                frames[templateID] = image
                frameErrors.removeValue(forKey: templateID)
                previews[templateID] = nil
                previewLoadID = UUID()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFrame(templateID: String) async {
        guard let template = document.templates.first(where: { $0.id == templateID }),
              let fileName = template.frameFileName else {
            frames.removeValue(forKey: templateID)
            frameErrors.removeValue(forKey: templateID)
            return
        }
        loadingFrameIDs.insert(templateID)
        defer { loadingFrameIDs.remove(templateID) }
        do {
            guard let data = try await coordinator.experienceStore.readTemplateFrame(
                eventID: event.id,
                templateID: templateID,
                fileName: fileName
            ),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                frames.removeValue(forKey: templateID)
                frameErrors[templateID] = "Template image unavailable."
                return
            }
            frames[templateID] = image
            frameErrors.removeValue(forKey: templateID)
        } catch is CancellationError {
            return
        } catch {
            frames.removeValue(forKey: templateID)
            frameErrors[templateID] = "Template image unavailable."
        }
    }

    private func importPromptImage(_ url: URL, templateID: String, photoIndex: Int) {
        Task {
            do {
                guard let templateIndex = document.templates.firstIndex(where: { $0.id == templateID }),
                      let promptIndex = document.templates[templateIndex].posePrompts.firstIndex(where: { $0.photoIndex == photoIndex }) else { return }
                let promptID = document.templates[templateIndex].posePrompts[promptIndex].id
                let imported = try await coordinator.experienceStore.importPromptImage(
                    eventID: event.id,
                    promptID: promptID,
                    sourceURL: url
                )
                document.templates[templateIndex].posePrompts[promptIndex].imageFileName = imported.fileName
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadPreviews() async throws {
        let templates = document.templates.filter { $0.isEnabled && previews[$0.id] == nil }
        guard !templates.isEmpty else { return }
        let dataByID = try await coordinator.experienceStore.readTemplatePreviews(
            eventID: event.id,
            templates: templates
        )
        for template in templates {
            try Task.checkCancellation()
            guard let data = dataByID[template.id],
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            previews[template.id] = image
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await coordinator.saveExperienceDocument(document, for: event)
                for template in document.templates {
                    _ = try await coordinator.experienceStore.rebuildPreview(
                        eventID: event.id,
                        templateID: template.id
                    )
                }
                coordinator.refreshActiveExperience()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private var operatorLanguage: CustomerLanguage {
        locale.identifier.lowercased().hasPrefix("th") ? .thai : .english
    }
}

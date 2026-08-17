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
    @State private var foregroundOverlays: [String: CGImage] = [:]
    @State private var isLoading = true
    @State private var isLoadingPreviews = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var editingTemplateID: String?
    @State private var previewLoadID = UUID()
    @State private var editingSession: EventExperienceEditingSession?

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

                    Section("GIF quality") {
                        Picker("GIF quality", selection: $document.gifQualityPreset) {
                            Text("Compact — Smaller file, fastest guest download").tag(GIFQualityPreset.compact)
                            Text("Balanced — Recommended").tag(GIFQualityPreset.balanced)
                            Text("High — Best quality, larger file").tag(GIFQualityPreset.high)
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
                Button("Back", action: discardAndDismiss)
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
            var session: EventExperienceEditingSession?
            do {
                session = try await coordinator.experienceStore.beginEditing(eventID: event.id)
                document = try await coordinator.loadExperienceDocument(for: event)
                editingSession = session
                selectedTemplateID = document.defaultTemplateID
                isLoading = false
                previewLoadID = UUID()
            } catch is CancellationError {
                if let session { try? await coordinator.experienceStore.discardEditing(session) }
                return
            } catch {
                if let session { try? await coordinator.experienceStore.discardEditing(session) }
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
            frames = frames.filter { templateIDs.contains($0.key) }
            foregroundOverlays = foregroundOverlays.filter { templateIDs.contains($0.key) }
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
                        frame: frames[template.id],
                        foregroundOverlay: foregroundOverlays[template.id]
                    ) { url in
                        importFrame(url, templateID: template.id)
                    } onImportForegroundOverlay: { url in
                        importForegroundOverlay(url, templateID: template.id)
                    } onRemoveForegroundOverlay: {
                        document.templates[index].foregroundOverlayFileName = nil
                        foregroundOverlays[template.id] = nil
                        previews[template.id] = nil
                        previewLoadID = UUID()
                    } onImportPromptImage: { photoIndex, url in
                        importPromptImage(url, templateID: template.id, photoIndex: photoIndex)
                    }
                    .navigationTitle(template.name.value(for: operatorLanguage))
                }
                .frame(minWidth: 560, minHeight: 620)
                .task {
                    await loadFrame(templateID: template.id)
                    await loadForegroundOverlay(templateID: template.id)
                }
            }
        }
        .onDisappear {
            guard let session = editingSession else { return }
            editingSession = nil
            Task { try? await coordinator.experienceStore.discardEditing(session) }
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
        Task { @MainActor in
            do {
                try await coordinator.experienceStore.duplicateTemplateAssets(
                    eventID: event.id,
                    sourceTemplateID: source.id,
                    destinationTemplateID: copy.id,
                    promptIDMap: promptIDMap,
                    editingSession: editingSession
                )
                frames[copy.id] = frames[source.id]
                previews[copy.id] = previews[source.id]
                previewLoadID = UUID()
            } catch {
                document.templates.removeAll { $0.id == copy.id }
                frames.removeValue(forKey: copy.id)
                previews.removeValue(forKey: copy.id)
                errorMessage = error.localizedDescription
            }
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
                    sourceURL: url,
                    editingSession: editingSession
                )
                guard let index = document.templates.firstIndex(where: { $0.id == templateID }) else { return }
                document.templates[index].frameFileName = imported.fileName
                document.templates[index].updatedAt = Date()
                guard let source = CGImageSourceCreateWithURL(imported.url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    frames[templateID] = nil
                    throw EventExperienceError.importFailed("Imported frame could not be decoded.")
                }
                frames[templateID] = image
                previews[templateID] = nil
                previewLoadID = UUID()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importForegroundOverlay(_ url: URL, templateID: String) {
        Task {
            do {
                let imported = try await coordinator.experienceStore.importTemplateForegroundOverlay(
                    eventID: event.id,
                    templateID: templateID,
                    sourceURL: url,
                    editingSession: editingSession
                )
                guard let index = document.templates.firstIndex(where: { $0.id == templateID }),
                      let image = loadCGImage(from: imported.url) else {
                    throw EventExperienceError.importFailed("Imported foreground overlay could not be decoded.")
                }
                document.templates[index].foregroundOverlayFileName = imported.fileName
                document.templates[index].updatedAt = Date()
                foregroundOverlays[templateID] = image
                previews[templateID] = nil
                previewLoadID = UUID()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFrame(templateID: String) async {
        do {
            guard frames[templateID] == nil else { return }
            guard let template = document.templates.first(where: { $0.id == templateID }),
                  let fileName = template.frameFileName else {
                frames[templateID] = nil
                return
            }
            guard let data = try await coordinator.experienceStore.readTemplateFrame(
                eventID: event.id,
                templateID: templateID,
                fileName: fileName,
                editingSession: editingSession
            ),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                frames[templateID] = nil
                return
            }
            guard frames[templateID] == nil else { return }
            frames[templateID] = image
        } catch is CancellationError {
            return
        } catch {
            frames[templateID] = nil
            errorMessage = "Template frame is missing or corrupt."
        }
    }

    private func loadForegroundOverlay(templateID: String) async {
        do {
            guard foregroundOverlays[templateID] == nil,
                  let template = document.templates.first(where: { $0.id == templateID }),
                  let fileName = template.foregroundOverlayFileName,
                  let data = try await coordinator.experienceStore.readTemplateForegroundOverlay(
                    eventID: event.id,
                    templateID: templateID,
                    fileName: fileName,
                    editingSession: editingSession
                  ),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            foregroundOverlays[templateID] = image
        } catch is CancellationError {
            return
        } catch {
            foregroundOverlays[templateID] = nil
            errorMessage = "Template foreground overlay is missing or corrupt."
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
                    sourceURL: url,
                    editingSession: editingSession
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
            templates: templates,
            editingSession: editingSession
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
                try await coordinator.saveExperienceDocument(
                    document,
                    for: event,
                    editingSession: editingSession
                )
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
                return
            }

            editingSession = nil
            var previewError: Error?
            for template in document.templates {
                do {
                    _ = try await coordinator.experienceStore.rebuildPreview(
                        eventID: event.id,
                        templateID: template.id
                    )
                } catch {
                    previewError = previewError ?? error
                }
            }
            coordinator.refreshActiveExperience()
            if let previewError {
                errorMessage = "Event saved. Template previews need rebuilding: \(previewError.localizedDescription)"
                isSaving = false
            } else {
                dismiss()
            }
        }
    }

    private func discardAndDismiss() {
        guard let session = editingSession else {
            dismiss()
            return
        }
        editingSession = nil
        Task {
            try? await coordinator.experienceStore.discardEditing(session)
            dismiss()
        }
    }

    private var operatorLanguage: CustomerLanguage {
        locale.identifier.lowercased().hasPrefix("th") ? .thai : .english
    }
}

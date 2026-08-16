import SwiftUI
import SwiftData

struct EventSetupView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    // Live query — updates automatically when events are added/deleted
    @Query(sort: \BoothEvent.createdAt, order: .reverse) private var events: [BoothEvent]

    @State private var selectedEventID: String?
    @State private var showNewEventSheet = false

    private var selectedEvent: BoothEvent? {
        events.first { $0.id == selectedEventID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedEventID) {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.name).font(.headline)
                            if event.isActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        Text(operatorPhotoSummary(
                            photoCount: event.photoCount,
                            countdownSeconds: event.countdownSeconds,
                            locale: locale
                        ))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(event.id)
                    .contextMenu {
                        Button("Set Active") { setActive(event) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(event) }
                    }
                }
            }
            .navigationTitle("Events (\(events.count))")
            .toolbar {
                ToolbarItem {
                    Button(action: { showNewEventSheet = true }) {
                        Label("New Event", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let event = selectedEvent {
                EventDetailView(event: event)
            } else {
                ContentUnavailableView {
                    Label("No Event Selected", systemImage: "calendar")
                } description: {
                    Text("Create an event with + or select one from the list.")
                }
            }
        }
        .sheet(isPresented: $showNewEventSheet) {
            NewEventSheet { name, count, seconds in
                let event = BoothEvent(name: name, photoCount: count, countdownSeconds: seconds)
                modelContext.insert(event)
                saveChanges()
                selectedEventID = event.id
            }
        }
    }

    private func setActive(_ event: BoothEvent) {
        events.forEach { $0.isActive = false }
        event.isActive = true
        saveChanges()
        coordinator.activeEvent = event
    }

    private func delete(_ event: BoothEvent) {
        if selectedEventID == event.id { selectedEventID = nil }
        if coordinator.activeEvent?.id == event.id { coordinator.activeEvent = nil }
        modelContext.delete(event)
        saveChanges()
    }

    private func saveChanges() {
        guard coordinator.store.saveChanges() else {
            coordinator.errorMessage = "Event changes could not be saved: \(coordinator.store.lastPersistenceError ?? "unknown error")"
            return
        }
    }
}

// MARK: - Event Detail

struct EventDetailView: View {
    @Bindable var event: BoothEvent
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @AppStorage("publicBaseURL") private var publicBaseURL: String = ""
    @State private var experienceDocument: EventExperienceDocument?
    @State private var experienceError: String?

    var body: some View {
        Form {
            Section("Event Info") {
                TextField("Name", text: $event.name)
                    .onSubmit { saveChanges() }
                Stepper("Countdown: \(event.countdownSeconds)s", value: $event.countdownSeconds, in: 3...15)
                    .onChange(of: event.countdownSeconds) { _, _ in saveChanges() }
            }

            Section("Status") {
                LabeledContent("Active") {
                    Toggle("", isOn: $event.isActive)
                        .onChange(of: event.isActive) { _, _ in saveChanges() }
                }
            }

            Section("Remote Access") {
                TextField("Public URL (optional)", text: $publicBaseURL)
                    .font(.caption.monospaced())
                Text("QR codes use this URL after cloud upload succeeds; otherwise they use the LAN server.\nExample: https://photos.yourdomain.com")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Default Template") {
                if let template = defaultTemplate {
                    LabeledContent("Name", value: template.name.english)
                    LabeledContent("Photos", value: "\(template.photoCount)")
                    LabeledContent("Canvas", value: "\(Int(template.canvasWidth)) × \(Int(template.canvasHeight)) px")
                    LabeledContent("Frame", value: template.frameFileName == nil ? "None" : "Imported")
                } else if let experienceError {
                    Text(experienceError).foregroundStyle(.red)
                } else {
                    ProgressView("Loading template…")
                }
                NavigationLink("Edit Guest Experience…") {
                    EventExperienceEditorView(event: event)
                }
                Text("Guest Experience is the source of truth. Legacy event layout fields remain as a compatibility mirror.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Camera") {
                Picker("Rotation", selection: $event.cameraRotationDegrees) {
                    Text("0° (default)").tag(0)
                    Text("90° CW").tag(90)
                    Text("180°").tag(180)
                    Text("270° CW").tag(270)
                }
                .onChange(of: event.cameraRotationDegrees) { _, _ in saveChanges() }
            }

        }
        .formStyle(.grouped)
        .navigationTitle(event.name)
        .navigationSubtitle(LocalizedStringKey(event.isActive ? "Active" : "Inactive"))
        .task(id: event.id) {
            do {
                experienceDocument = try await coordinator.loadExperienceDocument(for: event)
            } catch {
                experienceError = error.localizedDescription
            }
        }
    }

    private var defaultTemplate: EventTemplateDefinition? {
        guard let experienceDocument else { return nil }
        return experienceDocument.templates.first { $0.id == experienceDocument.defaultTemplateID }
    }

    private func saveChanges() {
        guard coordinator.store.saveChanges() else {
            experienceError = "Event changes could not be saved: \(coordinator.store.lastPersistenceError ?? "unknown error")"
            return
        }
    }
}

// MARK: - New Event Sheet

struct NewEventSheet: View {
    var onSave: (String, Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Event"
    @State private var photoCount = 3
    @State private var countdown = 5

    var body: some View {
        VStack(spacing: 0) {
            Text("New Event")
                .font(.title2.bold())
                .padding(.top, 24)
                .padding(.bottom, 16)

            Form {
                TextField("Event Name", text: $name)
                Stepper("Photos: \(photoCount)", value: $photoCount, in: 1...8)
                Stepper("Countdown: \(countdown)s", value: $countdown, in: 3...15)
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Create") {
                    onSave(name, photoCount, countdown)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
        }
        .frame(width: 360, height: 300)
    }
}

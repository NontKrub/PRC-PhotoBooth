import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ImageIO

struct EventSetupView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    // Live query — updates automatically when events are added/deleted
    @Query(sort: \BoothEvent.createdAt, order: .reverse) private var events: [BoothEvent]

    @State private var selectedEventID: String?
    @State private var showNewEventSheet = false
    @State private var showSlotEditor = false

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
                EventDetailView(event: event, onFrameEdit: { showSlotEditor = true })
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
                try? modelContext.save()
                selectedEventID = event.id
            }
        }
        .sheet(isPresented: $showSlotEditor) {
            if let event = selectedEvent {
                FrameSlotEditor(event: event)
            }
        }
    }

    private func setActive(_ event: BoothEvent) {
        events.forEach { $0.isActive = false }
        event.isActive = true
        try? modelContext.save()
        coordinator.activeEvent = event
    }

    private func delete(_ event: BoothEvent) {
        if selectedEventID == event.id { selectedEventID = nil }
        if coordinator.activeEvent?.id == event.id { coordinator.activeEvent = nil }
        modelContext.delete(event)
        try? modelContext.save()
    }
}

// MARK: - Event Detail

struct EventDetailView: View {
    @Bindable var event: BoothEvent
    @Environment(\.modelContext) private var modelContext
    @AppStorage("publicBaseURL") private var publicBaseURL: String = ""
    var onFrameEdit: () -> Void

    var body: some View {
        Form {
            Section("Event Info") {
                TextField("Name", text: $event.name)
                    .onSubmit { try? modelContext.save() }
                Stepper("Photos: \(event.photoCount)", value: $event.photoCount, in: 1...8)
                    .onChange(of: event.photoCount) { _, _ in try? modelContext.save() }
                Stepper("Countdown: \(event.countdownSeconds)s", value: $event.countdownSeconds, in: 3...15)
                    .onChange(of: event.countdownSeconds) { _, _ in try? modelContext.save() }
            }

            Section("Status") {
                LabeledContent("Active") {
                    Toggle("", isOn: $event.isActive)
                        .onChange(of: event.isActive) { _, _ in try? modelContext.save() }
                }
            }

            Section("Remote Access") {
                TextField("Public URL (optional)", text: $publicBaseURL)
                    .font(.caption.monospaced())
                Text("QR codes use this URL after cloud upload succeeds; otherwise they use the LAN server.\nExample: https://photos.yourdomain.com")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Frame Template") {
                HStack {
                    if let path = event.framePNGPath {
                        Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text("No frame imported").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import PNG…") { importFrame() }
                }
                Button("Edit Photo Slots…", action: onFrameEdit)
                    .buttonStyle(.bordered)
                    .disabled(event.slots.isEmpty && event.framePNGPath == nil)
            }

            Section("Guest Experience") {
                NavigationLink("Edit Templates, Filters & Gallery") {
                    EventExperienceEditorView(event: event)
                }
                Text("Version 1.2 options are stored separately from the legacy event layout.")
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
                .onChange(of: event.cameraRotationDegrees) { _, _ in try? modelContext.save() }
            }

            Section("Canvas Size") {
                HStack(spacing: 12) {
                    Text("Width")
                    TextField("Width", value: $event.canvasWidth, format: .number)
                        .frame(width: 80)
                        .onSubmit { try? modelContext.save() }
                    Text("×  Height")
                    TextField("Height", value: $event.canvasHeight, format: .number)
                        .frame(width: 80)
                        .onSubmit { try? modelContext.save() }
                    Text("px")
                }
            }

            Section("Photo Slots") {
                if event.slots.isEmpty {
                    Text("No slots defined — import a frame and use Edit Photo Slots.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(event.slots.sorted { $0.zOrder < $1.zOrder }) { slot in
                        HStack {
                            Text("Slot \(slot.zOrder + 1)")
                            Spacer()
                            Text(String(format: "x%.2f y%.2f  %.0f%%×%.0f%%",
                                        slot.normX, slot.normY,
                                        slot.normW * 100, slot.normH * 100))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(event.name)
        .navigationSubtitle(LocalizedStringKey(event.isActive ? "Active" : "Inactive"))
    }

    private func importFrame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let destDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("PRC-PhotoBooth/Frames")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: dest)
        event.framePNGPath = "Frames/\(url.lastPathComponent)"
        // Sync canvas dimensions to the PNG's actual pixel size
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
           let w = props[kCGImagePropertyPixelWidth as String] as? Double,
           let h = props[kCGImagePropertyPixelHeight as String] as? Double {
            event.canvasWidth = w
            event.canvasHeight = h
        }
        try? modelContext.save()
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

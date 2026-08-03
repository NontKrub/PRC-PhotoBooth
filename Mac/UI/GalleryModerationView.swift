import SwiftUI
import AppKit

struct GalleryModerationView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.locale) private var locale
    @State private var indexes: [EventGalleryIndex] = []
    @State private var selectedEventID = ""
    @State private var statusFilter: GalleryApprovalStatus?
    @State private var selectedSessionIDs: Set<String> = []
    @State private var confirmBulkHide = false
    @State private var isLoading = false

    private var selectedIndex: EventGalleryIndex? {
        indexes.first { $0.eventID == selectedEventID } ?? indexes.first
    }

    private var operatorLanguage: CustomerLanguage {
        operatorCustomerLanguage(for: locale)
    }

    var body: some View {
        GroupBox("Gallery Moderation") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Event", selection: $selectedEventID) {
                        ForEach(indexes, id: \.eventID) { index in
                            Text(index.title.value(for: operatorLanguage)).tag(index.eventID)
                        }
                    }
                    Picker("Status", selection: $statusFilter) {
                        Text("All").tag(GalleryApprovalStatus?.none)
                        ForEach(GalleryApprovalStatus.allCases, id: \.self) {
                            Text(operatorGalleryStatusName($0, locale: locale)).tag(Optional($0))
                        }
                    }
                    Button("Refresh") { load() }
                }
                HStack {
                    Button("Approve All Pending") { bulkSet(.approved, onlyPending: true) }
                        .disabled(selectedIndex == nil)
                    Button("Hide Selected", role: .destructive) { confirmBulkHide = true }
                        .disabled(selectedSessionIDs.isEmpty)
                    if !selectedSessionIDs.isEmpty {
                        Button("Clear Selection") { selectedSessionIDs.removeAll() }
                    }
                }
                if let index = selectedIndex {
                    let entries = index.sessions.filter { statusFilter == nil || $0.approvalStatus == statusFilter }
                    if entries.isEmpty {
                        Text("No gallery sessions match this filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(entries) { entry in
                                galleryCard(entry, index: index)
                            }
                        }
                    }
                } else if isLoading {
                    ProgressView("Loading gallery…")
                } else {
                    Text("No gallery indexes yet. Complete a session with gallery enabled.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { load() }
        .alert("Hide selected gallery sessions?", isPresented: $confirmBulkHide) {
            Button("Cancel", role: .cancel) {}
            Button("Hide", role: .destructive) { bulkSet(.hidden, onlyPending: false) }
        } message: {
            Text("Individual download pages will remain available.")
        }
    }

    private func galleryCard(_ entry: GallerySessionEntry, index: EventGalleryIndex) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = NSImage(contentsOfFile: URL(fileURLWithPath: entry.absoluteSessionDirectoryPath)
                .appendingPathComponent(entry.thumbnailFileName).path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(.black, in: RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.secondary.opacity(0.15))
                    .frame(height: 170)
                    .overlay(Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary))
            }
            HStack {
                Toggle("Select", isOn: Binding(
                    get: { selectedSessionIDs.contains(entry.id) },
                    set: { isSelected in
                        if isSelected { selectedSessionIDs.insert(entry.id) }
                        else { selectedSessionIDs.remove(entry.id) }
                    }
                ))
                .labelsHidden()
                Text(entry.startedAt, style: .date).font(.headline)
            }
            Text("\(entry.templateName.value(for: operatorLanguage)) · \(entry.filterID.displayName(for: operatorLanguage))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(operatorGalleryStatusName(entry.approvalStatus, locale: locale))
                .font(.caption.bold())
                .foregroundStyle(entry.approvalStatus == .approved ? .green : entry.approvalStatus == .hidden ? .red : .orange)
            HStack {
                Button("Open Individual Page") { openIndividualPage(entry) }
                Button("Open Session Folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.absoluteSessionDirectoryPath)
                }
            }
            HStack {
                Button("Approve") { set(entry, eventID: index.eventID, status: .approved) }
                    .disabled(entry.approvalStatus == .approved)
                Button("Pending") { set(entry, eventID: index.eventID, status: .pending) }
                Button("Hide") { set(entry, eventID: index.eventID, status: .hidden) }
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func set(_ entry: GallerySessionEntry, eventID: String, status: GalleryApprovalStatus) {
        Task {
            try? await coordinator.galleryStore.setApproval(
                eventID: eventID,
                sessionID: entry.sessionID,
                status: status
            )
            await coordinator.refreshServerRoutes()
            load()
        }
    }

    private func bulkSet(_ status: GalleryApprovalStatus, onlyPending: Bool) {
        guard let index = selectedIndex else { return }
        Task {
            let entries = index.sessions.filter { entry in
                onlyPending ? entry.approvalStatus == .pending : selectedSessionIDs.contains(entry.id)
            }
            for entry in entries {
                try? await coordinator.galleryStore.setApproval(
                    eventID: index.eventID,
                    sessionID: entry.sessionID,
                    status: status
                )
            }
            selectedSessionIDs.removeAll()
            await coordinator.refreshServerRoutes()
            load()
        }
    }

    private func openIndividualPage(_ entry: GallerySessionEntry) {
        guard !coordinator.serverURL.isEmpty,
              let url = URL(string: "\(coordinator.serverURL)/s/\(entry.downloadToken)/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func load() {
        isLoading = true
        Task {
            let loaded = await coordinator.galleryStore.loadAll()
            indexes = loaded.compactMap {
                if case .loaded(let index) = $0 { return index }
                return nil
            }
            if !indexes.contains(where: { $0.eventID == selectedEventID }) {
                selectedEventID = indexes.first?.eventID ?? ""
            }
            isLoading = false
        }
    }
}

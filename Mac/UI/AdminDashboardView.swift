import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers

struct AdminDashboardView: View {
    let onPINReset: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BoothSession.startedAt, order: .reverse) private var allSessions: [BoothSession]
    @Query(sort: \BoothEvent.createdAt, order: .reverse)   private var allEvents: [BoothEvent]

    @State private var startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State private var endDate   = Date()
    @State private var selectedEventFilter: String? = nil   // nil = all events
    @State private var selectedSession: BoothSession? = nil
    @State private var showClearPIN = false


    // MARK: - Derived data

    private var filteredSessions: [BoothSession] {
        allSessions.filter {
            $0.startedAt >= startDate && $0.startedAt <= Calendar.current.date(byAdding: .day, value: 1, to: endDate)!
            && (selectedEventFilter == nil || $0.eventID == selectedEventFilter)
            && $0.finishedAt != nil
        }
    }

    private var dayStats: [(date: Date, sessions: Int, photos: Int)] {
        let cal = Calendar.current
        var map: [Date: (Int, Int)] = [:]
        for s in filteredSessions {
            let day = cal.startOfDay(for: s.startedAt)
            let prev = map[day] ?? (0, 0)
            map[day] = (prev.0 + 1, prev.1 + s.photoCount)
        }
        return map.map { ($0.key, $0.value.0, $0.value.1) }
                  .sorted { $0.date < $1.date }
    }

    private var hourStats: [(hour: Int, count: Int)] {
        var map: [Int: Int] = [:]
        for s in filteredSessions {
            let h = Calendar.current.component(.hour, from: s.startedAt)
            map[h, default: 0] += 1
        }
        return (0..<24).map { (hour: $0, count: map[$0] ?? 0) }
    }

    private var totalSessions: Int { filteredSessions.count }
    private var totalPhotos: Int   { filteredSessions.reduce(0) { $0 + $1.photoCount } }
    private var avgSessionDuration: Double {
        let durations = filteredSessions.compactMap { s -> Double? in
            guard let fin = s.finishedAt else { return nil }
            return fin.timeIntervalSince(s.startedAt)
        }
        return durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            // Left: session list
            sessionList
                .frame(minWidth: 220, maxWidth: 280)

            // Right: charts + stats
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    filterBar
                    summaryRow
                    if !dayStats.isEmpty { sessionsPerDayChart }
                    if !dayStats.isEmpty { busyHoursChart }
                    eventBreakdownTable
                }
                .padding()
            }
        }
        .navigationTitle("Analytics")
        .toolbar {
            ToolbarItemGroup {
                Button(action: exportCSV) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                Button(action: { showClearPIN = true }) {
                    Label("Reset PIN", systemImage: "lock.rotation")
                }
                .help("Remove the admin PIN (you will be prompted to create a new one next time)")
            }
        }
        .confirmationDialog("Reset Admin PIN?", isPresented: $showClearPIN) {
            Button("Reset PIN", role: .destructive, action: onPINReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be asked to create a new PIN now.")
        }
    }

    // MARK: - Session list (left panel)

    var sessionList: some View {
        List(filteredSessions, selection: $selectedSession) { session in
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.bold())
                HStack {
                    Text("\(session.photoCount) photos")
                    if let dur = sessionDuration(session) {
                        Text("· \(dur)")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if session.stripPath != nil {
                    Label("Output saved", systemImage: "checkmark.circle")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            .tag(session)
        }
        .listStyle(.sidebar)
        .overlay {
            if filteredSessions.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "camera.slash",
                    description: Text("Sessions in this date range will appear here."))
            }
        }
    }

    // MARK: - Filter bar

    var filterBar: some View {
        HStack(spacing: 12) {
            DatePicker("From", selection: $startDate, displayedComponents: .date)
                .labelsHidden()
            Text("→")
            DatePicker("To", selection: $endDate, displayedComponents: .date)
                .labelsHidden()

            Divider().frame(height: 24)

            Picker("Event", selection: $selectedEventFilter) {
                Text("All Events").tag(String?.none)
                ForEach(allEvents) { event in
                    Text(event.name).tag(Optional(event.id))
                }
            }
            .frame(width: 160)

            Spacer()
            Text("\(totalSessions) sessions").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Summary cards

    var summaryRow: some View {
        HStack(spacing: 12) {
            StatCard(title: "Sessions",    value: "\(totalSessions)",        icon: "camera.fill",       color: .blue)
            StatCard(title: "Photos",      value: "\(totalPhotos)",           icon: "photo.stack",       color: .purple)
            StatCard(title: "Avg Duration",value: formatDuration(avgSessionDuration), icon: "timer", color: .orange)
            StatCard(title: "Events Run",  value: "\(Set(filteredSessions.map(\.eventID)).count)", icon: "calendar", color: .green)
        }
    }

    // MARK: - Charts

    var sessionsPerDayChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions per Day").font(.headline)
            Chart(dayStats, id: \.date) { stat in
                BarMark(x: .value("Date", stat.date, unit: .day),
                        y: .value("Sessions", stat.sessions))
                    .foregroundStyle(Color.accentColor.gradient)
                AreaMark(x: .value("Date", stat.date, unit: .day),
                         y: .value("Sessions", stat.sessions))
                    .foregroundStyle(Color.accentColor.opacity(0.1))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(1, dayStats.count / 7))) {
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .frame(height: 160)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    var busyHoursChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Busiest Hours").font(.headline)
            Chart(hourStats, id: \.hour) { stat in
                BarMark(x: .value("Hour", "\(stat.hour):00"),
                        y: .value("Sessions", stat.count))
                    .foregroundStyle(Color.purple.gradient)
            }
            .frame(height: 120)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Event breakdown table

    var eventBreakdownTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Event").font(.headline)
            let rows = eventRows()
            if rows.isEmpty {
                Text("No data").foregroundStyle(.secondary).font(.caption)
            } else {
                Table(rows) {
                    TableColumn("Event")    { Text($0.name) }
                    TableColumn("Sessions") { Text("\($0.sessions)") }.width(70)
                    TableColumn("Photos")   { Text("\($0.photos)") }.width(70)
                    TableColumn("Avg Retakes") { Text(String(format: "%.1f", $0.avgRetakes)) }.width(100)
                    TableColumn("Last Run") { Text($0.lastRun?.formatted(date: .abbreviated, time: .omitted) ?? "–") }.width(120)
                }
                .frame(height: min(CGFloat(rows.count) * 32 + 36, 260))
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private struct EventRow: Identifiable {
        let id: String
        let name: String
        let sessions: Int
        let photos: Int
        let avgRetakes: Double
        let lastRun: Date?
    }

    private func eventRows() -> [EventRow] {
        allEvents.compactMap { event in
            let sessions = filteredSessions.filter { $0.eventID == event.id }
            guard !sessions.isEmpty else { return nil }
            let allShots = sessions.flatMap { $0.shots }
            let avgRetakes = allShots.isEmpty ? 0.0 : Double(allShots.reduce(0) { $0 + $1.retakeCount }) / Double(allShots.count)
            return EventRow(id: event.id, name: event.name, sessions: sessions.count,
                            photos: sessions.reduce(0) { $0 + $1.photoCount },
                            avgRetakes: avgRetakes,
                            lastRun: sessions.map(\.startedAt).max())
        }.sorted { $0.sessions > $1.sessions }
    }

    private func sessionDuration(_ s: BoothSession) -> String? {
        guard let fin = s.finishedAt else { return nil }
        let secs = Int(fin.timeIntervalSince(s.startedAt))
        return "\(secs / 60)m \(secs % 60)s"
    }

    private func formatDuration(_ t: Double) -> String {
        guard t > 0 else { return "—" }
        let s = Int(t)
        return "\(s / 60)m \(s % 60)s"
    }

    // MARK: - CSV export

    private func exportCSV() {
        var lines = ["Date,Time,Event,Photos,Duration (s),Strip,GIF"]
        for s in filteredSessions {
            let eventName = allEvents.first { $0.id == s.eventID }?.name ?? s.eventID
            let dur = s.finishedAt.map { Int($0.timeIntervalSince(s.startedAt)) } ?? 0
            let date = s.startedAt.formatted(.dateTime.year().month().day())
            let time = s.startedAt.formatted(.dateTime.hour().minute().second())
            lines.append("\(date),\(time),\"\(eventName)\",\(s.photoCount),\(dur),\(s.stripPath ?? ""),\(s.gifPath ?? "")")
        }
        let csv = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "photobooth-sessions.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Stat card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

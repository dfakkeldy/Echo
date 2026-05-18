import SwiftUI

struct SchedulingSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let audiobookID: String
    let startPosition: TimeInterval?
    let endPosition: TimeInterval?

    @State private var title: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date().addingTimeInterval(1800)
    @State private var targetSpeed: Double = 1.0

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("Title", text: $title)
                }

                Section("Schedule") {
                    DatePicker("Start", selection: $startDate)

                    DatePicker("End", selection: $endDate)
                }

                Section("Playback Speed") {
                    Picker("Speed", selection: $targetSpeed) {
                        ForEach(speeds, id: \.self) { speed in
                            Text(String(format: "%.1f", speed) + "x").tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Content to cover")
                        Spacer()
                        if let start = startPosition, let end = endPosition {
                            Text(formatHMS(end - start))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Open-ended")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Time available")
                        Spacer()
                        Text(formatDuration(endDate.timeIntervalSince(startDate)))
                            .foregroundStyle(.secondary)
                    }

                    if let start = startPosition, let end = endPosition {
                        let contentDuration = end - start
                        let timeBlock = endDate.timeIntervalSince(startDate)
                        let needed = timeBlock > 0 ? contentDuration / timeBlock : 3.0

                        if needed > targetSpeed {
                            Text("At \(String(format: "%.1f", targetSpeed))x, you'll need \(String(format: "%.1f", needed))x to finish in this block.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Schedule Listening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSession()
                        dismiss()
                    }
                }
            }
            .onAppear {
                title = String(localized: "Listening Session")
            }
        }
    }

    private func saveSession() {
        guard let db = model.databaseService else { return }
        let dao = PlannedSessionDAO(db: db.writer)
        let session = PlannedSession(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            title: title.isEmpty ? String(localized: "Listening Session") : title,
            startTime: startDate,
            endTime: endDate,
            startPosition: startPosition,
            endPosition: endPosition,
            targetSpeed: targetSpeed,
            isCompleted: false,
            createdAt: Date()
        )
        do {
            try dao.insert(session.toRecord())
        } catch {
            // Fail silently — the timeline will refresh from DB
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

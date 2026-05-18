import SwiftUI

struct TimelineTab: View {
    @Environment(PlayerModel.self) private var model
    @State private var service: TimelineService?
    @State private var timeScale: TimeScale = .minutes
    @State private var timelineMode: TimelineService.TimelineMode = .realTime
    @State private var isViewingMode: Bool = true
    @State private var recenterTrigger = 0

    var body: some View {
        VStack(spacing: 0) {
            TimelineHeaderView(
                timeScale: $timeScale,
                timelineMode: $timelineMode,
                isViewingMode: $isViewingMode,
                onRecenterNow: {
                    service?.recenterOnNow()
                    recenterTrigger += 1
                }
            )

            Divider()

            if let service {
                TimelineContentView(service: service, isEditing: $isViewingMode.negated(), recenterTrigger: recenterTrigger)
            } else {
                ContentUnavailableView(
                    "Timeline",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Your listening timeline and planning surface will appear here.")
                )
            }
        }
        .onAppear {
            if service == nil, let db = model.databaseService {
                let ts = TimelineService(databaseService: db)
                ts.setCurrentAudiobookID(model.folderURL?.absoluteString)
                service = ts
                ts.recenterOnNow()
            }
        }
        .onChange(of: timeScale) { _, new in
            service?.setTimeScale(new)
        }
        .onChange(of: timelineMode) { _, new in
            service?.setTimelineMode(new)
        }
        .onChange(of: model.folderURL) { _, newURL in
            service?.setCurrentAudiobookID(newURL?.absoluteString)
        }
    }
}

private extension Binding where Value == Bool {
    func negated() -> Binding<Bool> {
        Binding<Bool>(
            get: { !wrappedValue },
            set: { wrappedValue = !$0 }
        )
    }
}

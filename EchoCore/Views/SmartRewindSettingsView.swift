import SwiftUI

struct SmartRewindSettingsView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section(
                footer: Text("Automatically rewinds on resume. Longer pause rules override shorter pause rules.")
            ) {
                Toggle("Enable Smart Rewind", isOn: $settings.isRewindEnabled)
            }

            if settings.isRewindEnabled {
                Section("Short Pauses") {
                    InlineStepperRow(
                        title: String(localized: "Trigger after:"),
                        value: $settings.rewindPauseSecondsThreshold,
                        range: 5...300,
                        step: 5,
                        valueText: "\(settings.rewindPauseSecondsThreshold)s"
                    )
                    InlineStepperRow(
                        title: String(localized: "Rewind by:"),
                        value: $settings.rewindAmountAfterSeconds,
                        range: 5...180,
                        step: 5,
                        valueText: "\(settings.rewindAmountAfterSeconds)s"
                    )
                }

                Section("Medium Pauses") {
                    InlineStepperRow(
                        title: String(localized: "Trigger after:"),
                        value: $settings.rewindPauseMinutesThreshold,
                        range: 1...120,
                        step: 1,
                        valueText: "\(settings.rewindPauseMinutesThreshold)m"
                    )
                    InlineStepperRow(
                        title: String(localized: "Rewind by:"),
                        value: $settings.rewindAmountAfterMinutes,
                        range: 10...600,
                        step: 5,
                        valueText: "\(settings.rewindAmountAfterMinutes)s"
                    )
                }

                Section("Long Pauses") {
                    InlineStepperRow(
                        title: String(localized: "Trigger after:"),
                        value: $settings.rewindPauseHoursThreshold,
                        range: 1...24,
                        step: 1,
                        valueText: "\(settings.rewindPauseHoursThreshold)h"
                    )
                    if !settings.rewindHoursToChapterStart {
                        InlineStepperRow(
                            title: String(localized: "Rewind by:"),
                            value: $settings.rewindAmountAfterHours,
                            range: 15...3600,
                            step: 15,
                            valueText: "\(settings.rewindAmountAfterHours)s"
                        )
                    }
                    Toggle("Jump to chapter start", isOn: $settings.rewindHoursToChapterStart)
                }
            }
        }
        .navigationTitle("Smart Rewind")
    }
}

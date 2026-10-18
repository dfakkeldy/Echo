// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct FeedbackFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SettingsManager.self) private var settings

    @State private var category: FeedbackCategory
    @State private var rating = 3
    @State private var message = ""
    @State private var includeDiagnostics = true
    @State private var diagnostics: FeedbackDiagnostics?
    @State private var alert: FeedbackFormAlert?

    private let recipient: String

    init(
        initialCategory: FeedbackCategory = .general,
        recipient: String = FeedbackMailBuilder.defaultRecipient
    ) {
        _category = State(initialValue: initialCategory)
        self.recipient = recipient
    }

    var body: some View {
        NavigationStack {
            Form {
                FeedbackRatingSection(rating: $rating)
                FeedbackCategorySection(category: $category)
                FeedbackMessageSection(message: $message)
                FeedbackDiagnosticsSection(
                    includeDiagnostics: $includeDiagnostics,
                    diagnostics: diagnostics
                )
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "paperplane", action: sendFeedback)
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .task {
                diagnostics = FeedbackDiagnosticsCollector.collect(
                    debugLoggingEnabled: settings.debugLoggingEnabled
                )
            }
        }
    }

    private func sendFeedback() {
        let entry = FeedbackEntry(
            category: category,
            rating: rating,
            message: message,
            diagnostics: includeDiagnostics ? diagnostics : nil
        )

        guard let url = FeedbackMailBuilder.mailtoURL(for: entry, recipient: recipient) else {
            alert = FeedbackFormAlert(
                title: String(localized: "Could Not Create Email"),
                message: String(localized: "Please try again from Settings.")
            )
            return
        }

        openURL(url)
        dismiss()
    }
}

private struct FeedbackRatingSection: View {
    @Binding var rating: Int

    var body: some View {
        Section {
            HStack {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        rating = value
                    } label: {
                        Image(systemName: value <= rating ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(value <= rating ? .yellow : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(value) of 5 stars"))
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("How is Echo feeling?")
        }
    }
}

private struct FeedbackCategorySection: View {
    @Binding var category: FeedbackCategory

    var body: some View {
        Section("Category") {
            Picker("Category", selection: $category) {
                ForEach(FeedbackCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .pickerStyle(.navigationLink)

            Text(category.prompt)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FeedbackMessageSection: View {
    @Binding var message: String

    var body: some View {
        Section("Message") {
            TextEditor(text: $message)
                .frame(minHeight: 140)
                .font(.body)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Tell us what happened, what helped, or what you expected.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct FeedbackDiagnosticsSection: View {
    @Binding var includeDiagnostics: Bool
    let diagnostics: FeedbackDiagnostics?

    var body: some View {
        Section {
            Toggle("Include device details", isOn: $includeDiagnostics)

            if includeDiagnostics, let diagnostics {
                DisclosureGroup("Included Details") {
                    Text(diagnostics.formattedString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Device details help reproduce bugs. They do not include book content.")
        }
    }
}

private struct FeedbackFormAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

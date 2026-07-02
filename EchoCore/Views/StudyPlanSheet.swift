// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StudyPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: StudyPlanViewModel

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isLoading {
                    ProgressView("Loading Study Plan")
                } else {
                    StudyPlanPacingSection(viewModel: viewModel)

                    if viewModel.existingPlan == nil {
                        StudyPlanCandidateSection(viewModel: viewModel)
                    } else {
                        StudyPlanManagementSection(viewModel: viewModel)
                    }
                }
            }
            .navigationTitle("Study Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.existingPlan == nil ? "Create" : "Save") {
                        if viewModel.save() {
                            dismiss()
                        }
                    }
                    .disabled(viewModel.existingPlan == nil && !viewModel.canCreatePlan)
                }
            }
            .alert(
                "Study Plan Error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task {
                viewModel.load()
            }
        }
    }
}

private struct StudyPlanPacingSection: View {
    @Bindable var viewModel: StudyPlanViewModel

    var body: some View {
        Section("Pacing") {
            Picker("Cadence", selection: $viewModel.cadenceUnit) {
                Text("Daily").tag(StudyPlanCadenceUnit.day)
                Text("Weekly").tag(StudyPlanCadenceUnit.week)
            }
            .pickerStyle(.segmented)

            Stepper(value: $viewModel.newChapterLimit, in: 1...12) {
                Text(viewModel.chapterLimitText)
            }

            if viewModel.canEditImageInclusion {
                Toggle("Create picture cards from EPUB images", isOn: $viewModel.includeImages)
                    .onChange(of: viewModel.includeImages) { _, _ in
                        viewModel.refreshPreviewForImageInclusionChange()
                    }
            }

            Picker("Queue Mode", selection: $viewModel.queueMode) {
                ForEach(StudyPlanQueueMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        }
    }
}

private struct StudyPlanCandidateSection: View {
    @Bindable var viewModel: StudyPlanViewModel

    var body: some View {
        Section {
            if viewModel.candidates.isEmpty {
                ContentUnavailableView(
                    "No Chapters Found",
                    systemImage: "rectangle.stack.badge.play",
                    description: Text("This book does not have eligible chapter headings for a study plan.")
                )
            } else {
                ForEach(viewModel.candidates) { candidate in
                    StudyPlanCandidateRow(candidate: candidate, viewModel: viewModel)
                }
            }
        } header: {
            Text("Assignments")
        } footer: {
            VStack(alignment: .leading) {
                Text("\(viewModel.selectedCandidateCount) selected")
                Text("Front matter and hidden chapters are excluded before this list is built.")
            }
        }
    }
}

private struct StudyPlanCandidateRow: View {
    let candidate: StudyPlanCandidate
    @Bindable var viewModel: StudyPlanViewModel

    var body: some View {
        let isSelected = viewModel.selectedCandidateIDs.contains(candidate.id)
        let kindTitle = candidate.kind == .image ? "Image" : "Chapter"
        let kindImage = candidate.kind == .image ? "photo" : "text.book.closed"

        Button {
            viewModel.toggleCandidate(candidate)
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading) {
                    Text(candidate.title)
                        .foregroundStyle(.primary)
                    Label(kindTitle, systemImage: kindImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isSelected ? "Included" : "Excluded"))
    }
}

private struct StudyPlanManagementSection: View {
    @Bindable var viewModel: StudyPlanViewModel

    var body: some View {
        Section("Status") {
            Toggle("Paused", isOn: $viewModel.isPaused)
            Text("Existing generated items stay in the review queue until graded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !viewModel.assignmentRows.isEmpty {
            Section {
                ForEach(viewModel.assignmentRows) { row in
                    Toggle(
                        isOn: Binding(
                            get: { viewModel.assignmentIsEnabled(row.id) },
                            set: { viewModel.setAssignmentEnabled(itemID: row.id, isEnabled: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Re-listen Cards")
            } footer: {
                Text(
                    "Turn a retired chapter back on when you want Echo to include its generated re-listen card in the study queue again."
                )
            }
        }
    }
}

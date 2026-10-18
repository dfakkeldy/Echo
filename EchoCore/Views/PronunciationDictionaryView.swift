// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Settings detail screen for the user's pronunciation-override dictionary. Each
/// row is a `word → IPA` pair; narration pronounces an overridden word from the
/// supplied IPA, bypassing the built-in lexicon (and the removed BART fallback).
/// Useful for proper nouns and technical terms the lexicon-only G2P can't guess
/// — e.g. "Kubernetes" → "kuːbərˈnɛtɪs".
///
/// Pushed from `SettingsView`, so it is a bare `Form` (no `NavigationStack` of
/// its own) and binds to the shared `PronunciationOverrideStore` so edits take
/// effect on the next chapter render. A plain `let` is enough for live updates:
/// reading `store.entries` in `body` registers the Observation dependency.
struct PronunciationDictionaryView: View {
    let store: PronunciationOverrideStore
    @State private var newWord: String = ""
    @State private var newIPA: String = ""
    /// Set when saving a pronunciation fails validation (e.g. non-IPA characters),
    /// driving an explanatory alert so the user fixes the entry instead of silently
    /// losing it — the old `try?` swallowed the error.
    @State private var saveError: String?

    /// Entries as a stably-ordered array so `ForEach`/`onDelete` indices map back
    /// to the right key (a `Dictionary` has no defined iteration order).
    private var sortedEntries: [(word: String, ipa: String)] {
        store.entries
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (word: $0.key, ipa: $0.value) }
    }

    var body: some View {
        Form {
            if !sortedEntries.isEmpty {
                Section {
                    ForEach(sortedEntries, id: \.word) { entry in
                        HStack {
                            Text(entry.word)
                                .bold()
                            Spacer()
                            Text(entry.ipa)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .onDelete(perform: deleteEntries)
                } header: {
                    Text("Saved pronunciations")
                } footer: {
                    Text(
                        "Words here are pronounced from the IPA you provide, overriding the built-in dictionary. Tip: for books full of invented names, add the main characters here."
                    )
                }
            }

            Section {
                TextField("Word", text: $newWord)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("IPA", text: $newIPA)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add pronunciation", systemImage: "plus.circle.fill", action: addEntry)
                    .disabled(trimmedWord.isEmpty || trimmedIPA.isEmpty)
            } header: {
                Text("Add a pronunciation")
            } footer: {
                Text(
                    "Enter IPA only — e.g. kuːbərˈnɛtɪs for Kubernetes. Stress marks: ˈ primary, ˌ secondary."
                )
            }
        }
        .navigationTitle("Pronunciation")
        .alert(
            "Can't save that pronunciation",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var trimmedWord: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedIPA: String {
        newIPA.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addEntry() {
        let word = trimmedWord
        let ipa = trimmedIPA
        guard !word.isEmpty, !ipa.isEmpty else { return }
        do {
            try store.set(word: word, ipa: ipa)
            newWord = ""
            newIPA = ""
        } catch {
            // Keep the fields populated so the user can fix the offending IPA.
            saveError = error.localizedDescription
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            try? store.remove(word: sortedEntries[index].word)
        }
    }
}

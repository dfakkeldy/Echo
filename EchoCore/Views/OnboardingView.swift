import SwiftUI

/// Simple first-launch welcome sheet explaining Echo's three core loops.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            TabView {
                welcomePage
                listenPage
                studyPage
                privacyPage
            }
            .tabViewStyle(.page)
            .navigationTitle("Welcome to Echo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Get Started") {
                        hasSeenOnboarding = true
                        dismiss()
                    }
                }
            }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Image(systemName: "headphones")
                .font(.system(size: 60))
                .foregroundStyle(.tint)
            Text("Your Audiobook Study Player")
                .font(.title)
                .fontWeight(.bold)
            Text("Listen, reflect, and remember — with tools designed for deep focus and distraction-free study.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private var listenPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Capture as You Listen")
                .font(.title2)
                .fontWeight(.bold)
            Text("Bookmark moments, record voice memos, and save photos — all without stopping playback.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private var studyPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "brain")
                .font(.system(size: 60))
                .foregroundStyle(.purple)
            Text("Study with Spaced Repetition")
                .font(.title2)
                .fontWeight(.bold)
            Text("Create flashcards from your bookmarks and review them daily. Import Anki decks to practice on the go.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    private var privacyPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Private by Design")
                .font(.title2)
                .fontWeight(.bold)
            Text("Everything stays on your device. No accounts, no tracking, no analytics. Your study data is yours alone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}

extension View {
    func onboardingSheet() -> some View {
        self.sheet(isPresented: .constant(!UserDefaults.standard.bool(forKey: "hasSeenOnboarding"))) {
            OnboardingView()
        }
    }
}

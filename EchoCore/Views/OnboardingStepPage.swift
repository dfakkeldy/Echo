// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct OnboardingStepPage: View {
    let step: OnboardingStep

    var body: some View {
        VStack {
            Image(systemName: step.systemImage)
                .font(.largeTitle)
                .imageScale(.large)
                .accessibilityHidden(true)
                .foregroundStyle(step.tint)

            Text(step.title)
                .font(.title2)
                .bold()

            Text(step.detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

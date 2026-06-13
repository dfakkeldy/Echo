import SwiftUI

// MARK: - TactilePlaygroundView

/// A page-style TabView wrapping the three tactile playgrounds:
/// Bubble Pop, Kinetic Sand, and Infinity Scroll.
struct TactilePlaygroundView: View {
    var body: some View {
        TabView {
            BubblePopView()
                .tag(0)
                .tabItem {
                    // tabItem is hidden by page style, but provides
                    // accessibility labels
                    Text("Bubble Pop")
                }

            KineticSandView()
                .tag(1)
                .tabItem {
                    Text("Kinetic Sand")
                }

            InfinityScrollView()
                .tag(2)
                .tabItem {
                    Text("Infinity Scroll")
                }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

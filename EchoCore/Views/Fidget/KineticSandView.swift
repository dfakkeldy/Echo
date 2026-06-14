import SwiftUI
import UIKit

// MARK: - KineticSandView

/// A simple particle-simulation canvas.
/// ~200 particles drift gently; dragging applies a repulsion force
/// so the sand flows away from your finger.
struct KineticSandView: View {
    @State private var particles: [SandParticle] = []
    @State private var dragLocation: CGPoint?
    @State private var lastUpdate = Date()
    @State private var canvasSize: CGSize = .zero

    struct SandParticle {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat = 0
        var vy: CGFloat = 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            Canvas { gc, _ in
                // Render only — physics is advanced outside the render pass.
                for p in particles {
                    let rect = CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)
                    gc.fill(Path(ellipseIn: rect), with: .color(.sand))
                }
            }
            // Advance the simulation from the timeline date in an action closure,
            // not inside Canvas: mutating @State during the render pass is
            // undefined behavior in SwiftUI (audit §8.1).
            .onChange(of: context.date) { _, now in
                let dt = min(now.timeIntervalSince(lastUpdate), 1 / 30)  // cap dt
                guard dt > 0, canvasSize != .zero else { return }
                lastUpdate = now
                updateParticles(size: canvasSize, dt: dt)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, size in canvasSize = size }
            }
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { dragLocation = $0.location }
                .onEnded { _ in dragLocation = nil }
        )
        .onAppear {
            populateParticles()
        }
    }

    // MARK: - Physics

    private func populateParticles() {
        particles = (0..<200).map { _ in
            SandParticle(
                x: CGFloat.random(in: 0...400),
                y: CGFloat.random(in: 0...800)
            )
        }
    }

    private func updateParticles(size: CGSize, dt: CGFloat) {
        let w = size.width
        let h = size.height

        for i in particles.indices {
            // Slow drift
            particles[i].vx += CGFloat.random(in: -4...4) * dt
            particles[i].vy += CGFloat.random(in: -4...4) * dt

            // Repulsion from finger
            if let loc = dragLocation {
                let dx = particles[i].x - loc.x
                let dy = particles[i].y - loc.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist > 0, dist < 120 {
                    let force = 600 / (dist + 10)
                    particles[i].vx += (dx / dist) * force * dt
                    particles[i].vy += (dy / dist) * force * dt
                }
            }

            // Damping
            particles[i].vx *= 0.97
            particles[i].vy *= 0.97

            // Clamp velocity
            let speed = sqrt(particles[i].vx * particles[i].vx + particles[i].vy * particles[i].vy)
            if speed > 300 {
                particles[i].vx = (particles[i].vx / speed) * 300
                particles[i].vy = (particles[i].vy / speed) * 300
            }

            // Apply
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt

            // Wrap around edges
            if particles[i].x < -10 { particles[i].x = w + 10 }
            if particles[i].x > w + 10 { particles[i].x = -10 }
            if particles[i].y < -10 { particles[i].y = h + 10 }
            if particles[i].y > h + 10 { particles[i].y = -10 }
        }
    }
}

// MARK: - Color Extension

extension Color {
    /// A warm sandy beige tone.
    /// Dimmer in dark mode so the sand doesn't glare against a dark surface (§8.3).
    static let sand = Color(
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.45, green: 0.40, blue: 0.28, alpha: 1)
                : UIColor(red: 0.76, green: 0.70, blue: 0.50, alpha: 1)
        })
}

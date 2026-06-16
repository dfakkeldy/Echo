// SPDX-License-Identifier: GPL-3.0-or-later
import MetalKit
import SwiftUI

// MARK: - VisualizerUniforms (Swift mirror of Metal struct)

/// Must match the `VisualizerUniforms` struct in `VisualizerShaders.metal` exactly.
struct VisualizerUniforms {
    var time: Float
    var rms: Float
    var peak: Float
    var spectrum: (Float, Float, Float, Float, Float, Float, Float, Float,
                   Float, Float, Float, Float, Float, Float, Float, Float)
}

extension VisualizerUniforms {
    init(time: Float, rms: Float, peak: Float, spectrum: [Float]) {
        var s = (Float(0), Float(0), Float(0), Float(0),
                 Float(0), Float(0), Float(0), Float(0),
                 Float(0), Float(0), Float(0), Float(0),
                 Float(0), Float(0), Float(0), Float(0))
        withUnsafeMutablePointer(to: &s) { ptr in
            // A homogeneous tuple is laid out contiguously, so the tuple
            // pointer can be reinterpreted as a Float buffer to fill it.
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { floatPtr in
                let buf = UnsafeMutableBufferPointer(start: floatPtr, count: 16)
                for i in 0..<min(spectrum.count, 16) {
                    buf[i] = spectrum[i]
                }
            }
        }
        self.time = time
        self.rms = rms
        self.peak = peak
        self.spectrum = s
    }
}

// MARK: - VisualizerView

/// A `UIViewRepresentable` wrapping an `MTKView` that renders audio-reactive
/// Metal shaders driven by an `AsyncStream<VisualizerFrame>`.
///
/// The view renders one of four fragment shaders depending on the `style`
/// binding.  Frame data (RMS, peak, 16-bin spectrum) is read on the main
/// thread from the latest value yielded by the stream and uploaded as a
/// uniform buffer each draw call.
struct VisualizerView: UIViewRepresentable {
    let style: VisualizerStyle
    let frameStream: AsyncStream<VisualizerFrame>

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.setStyle(style)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(style: style, frameStream: frameStream)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MTKViewDelegate {
        /// The system GPU device, created once and shared between the view's
        /// drawable and the command queue (audit §7.2).
        let device: MTLDevice?
        var style: VisualizerStyle
        var currentFrame: VisualizerFrame?
        private var startTime = CACurrentMediaTime()
        private var task: Task<Void, Never>?
        private var pipeline: MTLRenderPipelineState?
        private var commandQueue: MTLCommandQueue?

        init(style: VisualizerStyle, frameStream: AsyncStream<VisualizerFrame>) {
            self.style = style
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            super.init()

            commandQueue = device?.makeCommandQueue()

            task = Task { [weak self] in
                for await frame in frameStream {
                    self?.currentFrame = frame
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let device,
                  let commandQueue else { return }

            // Build pipeline once per style change
            if pipeline == nil || needsRebuild {
                pipeline = makePipeline(device: device, pixelFormat: drawable.texture.pixelFormat)
                needsRebuild = false
            }

            guard let pipeline else { return }

            var uniforms = VisualizerUniforms(
                time: Float(CACurrentMediaTime() - startTime),
                rms: currentFrame?.rms ?? 0,
                peak: currentFrame?.peak ?? 0,
                spectrum: currentFrame?.spectrum ?? [Float](repeating: 0, count: 16)
            )

            // Both can return nil under GPU memory pressure or app backgrounding
            // mid-draw — skip the frame rather than crash (audit §5.3).
            guard let buffer = commandQueue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VisualizerUniforms>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }

        // MARK: - Pipeline Management

        /// Track whether `style` has changed since the last pipeline build.
        private var needsRebuild = false
        private var lastStyle: VisualizerStyle?

        func setStyle(_ newStyle: VisualizerStyle) {
            if newStyle != lastStyle {
                style = newStyle
                lastStyle = newStyle
                needsRebuild = true
            }
        }

        private func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
            guard let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "vertexMain"),
                  let fragment = library.makeFunction(name: fragmentName) else { return nil }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            desc.colorAttachments[0].pixelFormat = pixelFormat
            return try? device.makeRenderPipelineState(descriptor: desc)
        }

        private var fragmentName: String {
            switch style {
            case .acidWarp: "acidWarpFragment"
            case .waveformRiver: "waveformRiverFragment"
            case .particleFlow: "particleFlowFragment"
            case .spectrumBars: "spectrumBarsFragment"
            }
        }

        deinit {
            task?.cancel()
        }
    }
}

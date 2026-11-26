import Foundation
import Metal

/// Process-wide Metal objects, created once and shared by every window:
/// - `MTLDevice`: the GPU.
/// - `MTLCommandQueue`: where we submit command buffers (one per frame).
/// - Pipeline states: a compiled shader pair plus fixed-function state (blending,
///   pixel format). Building them compiles shader code, so we do it once at launch.
@MainActor
public final class RenderContext {
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    let rectPipeline: any MTLRenderPipelineState
    let glyphPipeline: any MTLRenderPipelineState
    /// How long compiling the shaders from source took (shown in the debug overlay).
    public let shaderCompileMs: Double

    public enum SetupError: Error, CustomStringConvertible {
        case noDevice, shaderSourceMissing, compile(any Error)
        public var description: String {
            switch self {
            case .noDevice: "No Metal device"
            case .shaderSourceMissing: "Shaders.metal not found in the app bundle or source tree"
            case .compile(let e): "Shader compile failed: \(e)"
            }
        }
    }

    private static var _shared: RenderContext?

    public static func shared() throws -> RenderContext {
        if let s = _shared { return s }
        let s = try RenderContext()
        _shared = s
        return s
    }

    private init() throws {
        InstanceLayout.assertLayouts()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SetupError.noDevice
        }
        self.device = device
        self.queue = queue

        guard let source = Self.loadShaderSource() else { throw SetupError.shaderSourceMissing }
        let start = ContinuousClock.now
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw SetupError.compile(error)
        }
        shaderCompileMs = (ContinuousClock.now - start).milliseconds

        func pipeline(_ vertex: String, _ fragment: String) throws -> any MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            let color = desc.colorAttachments[0]!
            color.pixelFormat = Self.pixelFormat
            // Premultiplied-alpha "over" blending: out = src + dst × (1 − src.a).
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        rectPipeline = try pipeline("rect_vertex", "rect_fragment")
        glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
        print(String(format: "[metal] %@, shaders compiled in %.1f ms", device.name, shaderCompileMs))
    }

    /// In the .app: Contents/Resources/Shaders.metal (copied by the Makefile).
    /// Under `swift run`: Resources/Shaders.metal in the source tree.
    private static func loadShaderSource() -> String? {
        let candidates = [
            Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Shaders.metal"),
        ]
        for case let url? in candidates {
            if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        }
        return nil
    }
}

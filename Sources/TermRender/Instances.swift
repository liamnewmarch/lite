import TermCore

// Per-instance data uploaded to the GPU each frame. Layouts must match the structs
// in Resources/Shaders.metal byte for byte (checked by `assertLayouts()`).

struct RectInstance {
    var x: Int16, y: Int16      // px, top-left
    var w: Int16, h: Int16      // px
    var color: UInt32           // 0xRRGGBBAA
}

struct GlyphInstance {
    var x: Int16, y: Int16      // px, top-left on screen
    var w: UInt16, h: UInt16    // px
    var atlasX: UInt16, atlasY: UInt16
    var color: UInt32           // 0xRRGGBBAA
    var flags: UInt32           // bit 0: colour glyph
}

struct Uniforms {
    var viewportSize: SIMD2<Float>
}

enum InstanceLayout {
    static func assertLayouts() {
        assert(MemoryLayout<RectInstance>.stride == 12, "RectInstance must match Shaders.metal")
        assert(MemoryLayout<GlyphInstance>.stride == 20, "GlyphInstance must match Shaders.metal")
    }
}

extension RGB {
    func packed(alpha: UInt8 = 255) -> UInt32 {
        UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(alpha)
    }
}

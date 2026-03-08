#include <metal_stdlib>
using namespace metal;

// =============================================================================
// Conversion shaders: grayscale, downsample, and texture clearing
// =============================================================================

/// Convert BGRA (or RGBA) texture to grayscale using BT.601 luminance weights.
kernel void grayscale_kernel(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float4 color = input.read(gid);
    // BT.601 luminance: Y = 0.299*R + 0.587*G + 0.114*B
    float gray = dot(color.rgb, float3(0.299, 0.587, 0.114));
    output.write(float4(gray, gray, gray, 1.0), gid);
}

/// Downsample by 2x using a box filter (average of 2x2 neighborhood).
/// Output texture should be half the width and height of input.
kernel void downsample_kernel(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    uint2 srcPos = gid * 2;
    float4 sum = input.read(srcPos)
               + input.read(srcPos + uint2(1, 0))
               + input.read(srcPos + uint2(0, 1))
               + input.read(srcPos + uint2(1, 1));
    output.write(sum * 0.25, gid);
}

/// Clear a texture to zero (used for initializing accumulator textures).
kernel void clear_kernel(
    texture2d<float, access::write> output [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(float4(0.0, 0.0, 0.0, 0.0), gid);
}

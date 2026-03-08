#include "ShaderCommon.h"

// =============================================================================
// Tone Mapping Shader
// =============================================================================
// Implements a mild ACES-inspired filmic tone mapping curve.
// The goal is a natural "SLR-like" look:
//   - Gentle highlight roll-off (preserves detail, no hard clipping)
//   - Mild S-curve contrast (not aggressive)
//   - Slight shadow lift (film-like feel)
//   - No local tone mapping (avoids the "HDR-ish" look)

/// ACES-inspired filmic curve (Uncharted 2 variant, tuned for a mild look).
/// Input x is in linear light, typically [0, whitePoint].
/// Output is [0, 1] after the curve is applied and normalized.
float3 aces_filmic_mild(float3 x) {
    // Mild parameters (less aggressive than standard ACES)
    float a = 2.0;    // Shoulder strength
    float b = 0.30;   // Linear strength
    float c = 2.5;    // Linear angle
    float d = 0.60;   // Toe strength
    float e = 0.02;   // Toe numerator
    float f = 0.30;   // Toe denominator

    return ((x * (a * x + c * b) + d * e) /
            (x * (a * x + b) + d * f)) - e / f;
}

/// Main tone mapping kernel.
/// Takes linear-light merged image and produces display-ready sRGB output.
kernel void tonemap_kernel(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant ToneMapParams& params         [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float4 color = input.read(gid);
    float3 rgb = color.rgb;

    // 1. Exposure adjustment (linear multiply in scene-referred space)
    rgb *= pow(2.0, params.exposure);

    // 2. Apply filmic tone curve
    //    Normalize by the curve value at the white point so that
    //    the white point maps to 1.0
    float3 whiteScale = 1.0 / aces_filmic_mild(float3(params.whitePoint));
    rgb = aces_filmic_mild(rgb) * whiteScale;

    // 3. Linear to sRGB gamma (approximate with pow 1/2.2)
    rgb = pow(clamp(rgb, 0.0, 1.0), float3(1.0 / 2.2));

    // 4. Mild contrast S-curve in gamma space
    //    Pivots around mid-gray (0.5)
    float midGray = 0.5;
    rgb = midGray + (rgb - midGray) * (1.0 + params.contrast);
    rgb = clamp(rgb, 0.0, 1.0);

    // 5. Shadow lift (raises the black point slightly for a film look)
    rgb = rgb * (1.0 - params.shadowLift) + params.shadowLift;

    output.write(float4(rgb, 1.0), gid);
}

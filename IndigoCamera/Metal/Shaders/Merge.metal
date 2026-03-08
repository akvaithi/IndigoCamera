#include "ShaderCommon.h"

// =============================================================================
// Frame Merging Shaders
// =============================================================================
// These implement a robust weighted average with ghosting avoidance.
// Key idea: pixels that differ significantly from the reference (due to motion)
// get low weight, so moving objects don't cause ghosting in the merged result.
//
// Weight function: Cauchy (Lorentzian) distribution
//   w = 1 / (1 + (diff/sigma)^2)
// This is more robust to outliers than a Gaussian weight.

/// Compute per-pixel merge weight based on similarity to the reference frame.
/// Output: weight texture (R channel = weight value).
kernel void compute_merge_weight_kernel(
    texture2d<float, access::read>  reference [[texture(0)]],
    texture2d<float, access::read>  candidate [[texture(1)]],
    texture2d<float, access::write> weights   [[texture(2)]],
    constant MergeParams& params              [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= weights.get_width() || gid.y >= weights.get_height()) return;

    float4 refColor = reference.read(gid);
    float4 candColor = candidate.read(gid);

    // Per-channel absolute difference, averaged
    float3 diff = abs(refColor.rgb - candColor.rgb);
    float meanDiff = (diff.r + diff.g + diff.b) / 3.0;

    // Cauchy weight: robust to outliers (moving objects get low weight)
    float ratio = meanDiff / max(params.sigma, 0.001);
    float w = 1.0 / (1.0 + ratio * ratio);
    w *= params.frameWeight;

    weights.write(float4(w, 0.0, 0.0, 0.0), gid);
}

/// Accumulate a weighted frame into the running sum.
/// accumColor += candidate * weight
/// accumWeight += weight
kernel void accumulate_kernel(
    texture2d<float, access::read>       candidate   [[texture(0)]],
    texture2d<float, access::read>       weights     [[texture(1)]],
    texture2d<float, access::read_write> accumColor  [[texture(2)]],
    texture2d<float, access::read_write> accumWeight [[texture(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= accumColor.get_width() || gid.y >= accumColor.get_height()) return;

    float w = weights.read(gid).r;
    float4 color = candidate.read(gid);

    float4 prevColor = accumColor.read(gid);
    float prevWeight = accumWeight.read(gid).r;

    accumColor.write(prevColor + color * w, gid);
    accumWeight.write(float4(prevWeight + w, 0.0, 0.0, 0.0), gid);
}

/// Normalize the accumulated weighted sum to produce the final merged image.
/// output = accumColor / accumWeight
kernel void normalize_kernel(
    texture2d<float, access::read>  accumColor  [[texture(0)]],
    texture2d<float, access::read>  accumWeight [[texture(1)]],
    texture2d<float, access::write> output      [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float4 color = accumColor.read(gid);
    float w = accumWeight.read(gid).r;

    // Avoid division by zero; if no frames contributed, output black
    float4 result = (w > 0.001) ? color / w : float4(0.0, 0.0, 0.0, 1.0);
    result.a = 1.0;
    output.write(result, gid);
}

// =============================================================================
// HDR Exposure Fusion
// =============================================================================
// Mertens-style exposure fusion: each pixel from each exposure is weighted by
// how "well-exposed" it is. Pixels near mid-tone get highest weight because
// they carry the most information (not clipped highlights, not noisy shadows).
//
// Weight = well_exposedness * saturation_weight * contrast_weight
//
// Input is LINEAR light (from CIRAWFilter), so mid-tone = ~0.18 (18% gray).
// We apply a Gaussian centered at 0.18 for well-exposedness.

/// Compute HDR exposure fusion weight for a single frame.
/// Uses well-exposedness, saturation, and local contrast quality measures.
kernel void hdr_fusion_weight_kernel(
    texture2d<float, access::read>  frame   [[texture(0)]],
    texture2d<float, access::write> weights [[texture(1)]],
    constant MergeParams& params            [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= weights.get_width() || gid.y >= weights.get_height()) return;

    float4 pixel = frame.read(gid);
    float3 rgb = pixel.rgb;

    // Luminance in linear light
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));

    // 1. Well-exposedness: Gaussian centered at mid-gray (0.18 in linear).
    // Pixels near 0.18 are well-exposed; clipped highlights (>0.9) and
    // deep shadows (<0.01) get low weight.
    float wellExposed = exp(-0.5 * pow((lum - 0.18) / 0.20, 2.0));

    // Boost weight for very dark pixels slightly (shadow recovery)
    // and penalize clipped highlights heavily
    if (lum > 0.95) wellExposed *= 0.01;
    if (lum < 0.001) wellExposed *= 0.1;

    // 2. Saturation: well-saturated pixels carry more color information.
    float mu = (rgb.r + rgb.g + rgb.b) / 3.0;
    float sat = sqrt(((rgb.r - mu) * (rgb.r - mu) +
                      (rgb.g - mu) * (rgb.g - mu) +
                      (rgb.b - mu) * (rgb.b - mu)) / 3.0);
    float satWeight = sat + 0.01; // Small epsilon to avoid zero weight

    // Combined weight
    float w = wellExposed * satWeight * params.frameWeight;

    weights.write(float4(w, 0.0, 0.0, 0.0), gid);
}

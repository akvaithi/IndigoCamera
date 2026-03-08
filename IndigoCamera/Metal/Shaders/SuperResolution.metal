#include "ShaderCommon.h"

/// Warp and upsample a source-resolution frame onto the high-res output grid.
/// For each output pixel (ox, oy), sample from input at (ox * invScale + dx, oy * invScale + dy).
kernel void superres_warp_kernel(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant SuperResParams& params        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float srcX = float(gid.x) * params.invScale + params.dx;
    float srcY = float(gid.y) * params.invScale + params.dy;

    int x0 = int(floor(srcX));
    int y0 = int(floor(srcY));
    float fx = srcX - float(x0);
    float fy = srcY - float(y0);

    int w = input.get_width();
    int h = input.get_height();

    // Out-of-bounds: write alpha=0 to mark invalid
    if (x0 < 0 || x0 + 1 >= w || y0 < 0 || y0 + 1 >= h) {
        output.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    // Bilinear interpolation
    float4 v00 = input.read(uint2(x0,     y0));
    float4 v10 = input.read(uint2(x0 + 1, y0));
    float4 v01 = input.read(uint2(x0,     y0 + 1));
    float4 v11 = input.read(uint2(x0 + 1, y0 + 1));

    float4 result = mix(mix(v00, v10, fx), mix(v01, v11, fx), fy);
    result.a = 1.0;  // Mark as valid pixel
    output.write(result, gid);
}

/// Compute merge weight at high-res by comparing warped candidate to upsampled reference.
/// Same Cauchy weight as standard merge, but on the high-res grid.
kernel void superres_weight_kernel(
    texture2d<float, access::read>  reference [[texture(0)]],
    texture2d<float, access::read>  candidate [[texture(1)]],
    texture2d<float, access::write> weights   [[texture(2)]],
    constant MergeParams& params              [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= weights.get_width() || gid.y >= weights.get_height()) return;

    float4 candColor = candidate.read(gid);

    // If candidate pixel is out-of-bounds (alpha == 0), weight = 0
    if (candColor.a < 0.5) {
        weights.write(float4(0.0), gid);
        return;
    }

    float4 refColor = reference.read(gid);
    float3 diff = abs(refColor.rgb - candColor.rgb);
    float meanDiff = (diff.r + diff.g + diff.b) / 3.0;
    float ratio = meanDiff / max(params.sigma, 0.001);
    float w = 1.0 / (1.0 + ratio * ratio);
    w *= params.frameWeight;

    weights.write(float4(w, 0.0, 0.0, 0.0), gid);
}

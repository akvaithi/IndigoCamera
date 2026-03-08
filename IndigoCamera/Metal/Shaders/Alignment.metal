#include "ShaderCommon.h"

// =============================================================================
// Frame Alignment Shaders
// =============================================================================
// These implement a coarse-to-fine pyramid alignment using Sum of Absolute
// Differences (SAD). The algorithm:
//   1. Build a Gaussian pyramid for reference and candidate frames
//   2. At the coarsest level, exhaustively search for best (dx, dy)
//   3. Refine at each finer level with a smaller search window
//   4. Apply the final translation warp at full resolution

/// Compute Sum of Absolute Differences (SAD) between the reference and
/// a translated version of the candidate, for a grid of candidate offsets.
///
/// Each thread handles one (dx, dy) offset. The SAD is computed by sampling
/// a sparse grid of pixels (controlled by sampleStep) for speed.
///
/// Output: sadOutput buffer where sadOutput[dy_idx * searchDiam + dx_idx] = SAD value
kernel void compute_sad_kernel(
    texture2d<float, access::read> ref       [[texture(0)]],
    texture2d<float, access::read> cand      [[texture(1)]],
    device float* sadOutput                   [[buffer(0)]],
    constant AlignmentParams& params          [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    int searchDiam = 2 * params.searchRadius + 1;

    // Each thread corresponds to one (dx_offset, dy_offset) in the search grid
    if (int(gid.x) >= searchDiam || int(gid.y) >= searchDiam) return;

    int dx = int(gid.x) - params.searchRadius + params.baseDx;
    int dy = int(gid.y) - params.searchRadius + params.baseDy;

    int w = ref.get_width();
    int h = ref.get_height();

    // Compute SAD over a sampled grid of points (not every pixel - faster)
    int step = max(1, params.sampleStep);
    int margin = max(abs(params.searchRadius) + abs(params.baseDx),
                     abs(params.searchRadius) + abs(params.baseDy)) + 2;

    float sad = 0.0;
    int count = 0;

    for (int y = margin; y < h - margin; y += step) {
        for (int x = margin; x < w - margin; x += step) {
            float refVal = ref.read(uint2(x, y)).r;
            int cx = x + dx;
            int cy = y + dy;
            if (cx >= 0 && cx < w && cy >= 0 && cy < h) {
                float candVal = cand.read(uint2(cx, cy)).r;
                sad += abs(refVal - candVal);
                count++;
            }
        }
    }

    int idx = int(gid.y) * searchDiam + int(gid.x);
    sadOutput[idx] = (count > 0) ? sad / float(count) : 1e10;
}

/// Warp (translate) a texture by (dx, dy) with bilinear interpolation.
/// This is the final step after alignment - shifts the candidate to match
/// the reference frame.
kernel void warp_translate_kernel(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant WarpParams& params            [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    float srcX = float(gid.x) + params.dx;
    float srcY = float(gid.y) + params.dy;

    int x0 = int(floor(srcX));
    int y0 = int(floor(srcY));
    float fx = srcX - float(x0);
    float fy = srcY - float(y0);

    int w = input.get_width();
    int h = input.get_height();

    // Out of bounds: write black
    if (x0 < 0 || x0 + 1 >= w || y0 < 0 || y0 + 1 >= h) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    // Bilinear interpolation
    float4 v00 = input.read(uint2(x0,     y0));
    float4 v10 = input.read(uint2(x0 + 1, y0));
    float4 v01 = input.read(uint2(x0,     y0 + 1));
    float4 v11 = input.read(uint2(x0 + 1, y0 + 1));

    float4 result = mix(mix(v00, v10, fx), mix(v01, v11, fx), fy);
    output.write(result, gid);
}

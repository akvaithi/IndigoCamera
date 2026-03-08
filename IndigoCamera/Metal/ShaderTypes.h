#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

/// Parameters for the coarse-to-fine alignment search.
struct AlignmentParams {
    int searchRadius;    // Search window half-size (e.g., 32 at coarsest, 2 at finer levels)
    int baseDx;          // Inherited dx from coarser level (scaled by 2)
    int baseDy;          // Inherited dy from coarser level (scaled by 2)
    int sampleStep;      // Sampling step size (skip pixels for speed)
};

/// Translation warp parameters.
struct WarpParams {
    float dx;
    float dy;
};

/// Parameters for the robust merge weight computation.
struct MergeParams {
    float sigma;         // Noise-adaptive threshold (higher = more tolerant)
    float frameWeight;   // Base weight for this frame (reference gets higher weight)
};

/// Parameters for the filmic tone mapping shader.
struct ToneMapParams {
    float exposure;       // EV adjustment (e.g., +1.0 for HDR recovery)
    float contrast;       // Mid-tone contrast strength (0.0-0.5)
    float shadowLift;     // Shadow lift amount (0.0-0.1)
    float whitePoint;     // Scene-referred white point (e.g., 4.0)
};

/// Parameters for super-resolution warp + upsample.
struct SuperResParams {
    float dx;             // Sub-pixel offset in source coordinates
    float dy;
    float invScale;       // 1.0 / upscale_factor (e.g., 0.667 for 1.5x)
};

#endif /* ShaderTypes_h */

#ifndef ShaderCommon_h
#define ShaderCommon_h

#include <metal_stdlib>
using namespace metal;

// Shared type definitions used across all Metal shaders.

struct AlignmentParams {
    int searchRadius;
    int baseDx;
    int baseDy;
    int sampleStep;
};

struct WarpParams {
    float dx;
    float dy;
};

struct MergeParams {
    float sigma;
    float frameWeight;
};

struct ToneMapParams {
    float exposure;
    float contrast;
    float shadowLift;
    float whitePoint;
};

struct SuperResParams {
    float dx;
    float dy;
    float invScale;
};

#endif /* ShaderCommon_h */

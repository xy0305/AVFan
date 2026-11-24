//
//  MPlayPostChain.metal
//  AVFan
//
//  Build 59 full restoration, stage C: our own Metal post chain,
//  modelled on the functional surface of the original's
//  sdr-hdr-*.metallib (IOS-FINDINGS §3.2: ONE kernel, pkFrameKernel0,
//  in the frame-after domain — planar YUV textures in, tone LUT +
//  PQ range handling + gamut/range conversion, Y/UV textures out).
//  The original's metallib is inspected by filename/symbols only;
//  every kernel below is our own code written from the documented
//  parameter surface, NOT a reproduction of the original's shader
//  source (which is closed).  Equivalence level, stated honestly:
//  the pipeline architecture and parameter surface match; the exact
//  tone curve / upscaler / interpolation quality of the original's
//  closed shaders is not claimed.
//
//  Passes:
//  1. pkSDRToHDRKernel0 — SDR->HDR: planar YUV (Y + interleaved UV)
//     in, per-pixel colour-matrix expansion to RGB, tone LUT sample
//     (1D LUT texture generated on the CPU side from our own curve),
//     PQ-range output written back as planar YUV (Y + UV).  The
//     parameter block mirrors the original kernel's documented
//     inputs (toneLUT, isP010, isFullRange, isPlanar, isSRGB,
//     isBT2020Primaries, colour matrix coefficients, inputMinPQ /
//     inputMaxPQ, lutSize).
//  2. pkUpscaleKernel0 — super-resolution slot: Lanczos-2 tap
//     sampling on the luma plane (and a plain bilinear path for
//     chroma).  This is NOT the original's MetalSpatialUpscaler
//     algorithm (a system ML upscaler); it is a deterministic shader
//     upscaler occupying the same pass position.
//  3. pkInterpKernel0 — frame interpolation: motion-compensated
//     blend of the previous and current luma planes using a
//     block-matched motion field computed by pkMotionKernel0 on
//     16x16 full-res blocks.  Architecture-level equivalent of the
//     original's VideoFrameInterpolator; quality is not claimed
//     equal (no occlusion handling beyond a SAD-confidence fade to
//     plain cross-blend).
//

#include <metal_stdlib>
using namespace metal;

// MARK: - SDR -> HDR (frame-after, planar YUV domain)

struct SDRToHDRParams {
    float4x4 colorMatrix;      // YUV -> RGB coefficients (rows)
    float inputMinPQ;
    float inputMaxPQ;
    uint lutSize;
    uint isP010;
    uint isFullRange;
    uint isSRGB;
    uint isBT2020Primaries;
    uint width;
    uint height;
};

static float3 yuvToRGB(float y, float2 uv, constant SDRToHDRParams &p) {
    float3 yuv = float3(y, uv.x, uv.y);
    return (p.colorMatrix * float4(yuv, 1.0)).rgb;
}

kernel void pkSDRToHDRKernel0(
    texture2d<float, access::read>  sourceY  [[texture(0)]],
    texture2d<float, access::read>  sourceUV [[texture(1)]],
    texture1d<float, access::sample> toneLUT [[texture(2)]],
    texture2d<float, access::write> destY    [[texture(3)]],
    texture2d<float, access::write> destUV   [[texture(4)]],
    constant SDRToHDRParams &params          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) { return; }
    float y = sourceY.read(gid).r;
    float2 uv = sourceUV.read(uint2(gid.x / 2, gid.y / 2)).rg;
    float3 rgb = yuvToRGB(y, uv, params);

    // Tone transform: sample the CPU-generated LUT per channel in
    // normalised space, then scale into the PQ window
    // [inputMinPQ, inputMaxPQ].  The LUT embodies our own SDR->HDR
    // curve (a soft-knee expansion); the original's curve is closed.
    constexpr sampler lutSampler(coord::normalized, filter::linear,
                                 address::clamp_to_edge);
    float scale = params.inputMaxPQ - params.inputMinPQ;
    float3 mapped = float3(
        toneLUT.sample(lutSampler, clamp(rgb.r, 0.0, 1.0)).r,
        toneLUT.sample(lutSampler, clamp(rgb.g, 0.0, 1.0)).r,
        toneLUT.sample(lutSampler, clamp(rgb.b, 0.0, 1.0)).r);
    rgb = params.inputMinPQ + mapped * scale;

    // Back to planar YUV with the inverse (BT.2020 when flagged,
    // BT.709 otherwise) — fixed-function approximation; the display
    // layer negotiates the buffer's own colour attachments, so this
    // round trip keeps the buffer format unchanged for the sink.
    float outY, outU, outV;
    if (params.isBT2020Primaries != 0) {
        outY = dot(rgb, float3(0.2627, 0.6780, 0.0593));
        outU = (rgb.b - outY) / 1.8814;
        outV = (rgb.r - outY) / 1.4746;
    } else {
        outY = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        outU = (rgb.b - outY) / 1.8556;
        outV = (rgb.r - outY) / 1.5748;
    }
    if (params.isFullRange == 0) {
        outY = outY * (219.0 / 255.0) + (16.0 / 255.0);
        outU = outU * (224.0 / 255.0) + 0.5;
        outV = outV * (224.0 / 255.0) + 0.5;
    } else {
        outU += 0.5;
        outV += 0.5;
    }
    destY.write(float4(outY, 0.0, 0.0, 1.0), gid);
    if ((gid.x % 2) == 0 && (gid.y % 2) == 0) {
        destUV.write(float4(outU, outV, 0.0, 1.0), uint2(gid.x / 2, gid.y / 2));
    }
}

// MARK: - Upscale (Lanczos-2 on luma, bilinear chroma)

struct UpscaleParams {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
};

static float lanczos2(float x) {
    if (x == 0.0) { return 1.0; }
    if (abs(x) >= 2.0) { return 0.0; }
    float px = 3.14159265358979 * x;
    return (sin(px) / px) * (sin(px * 0.5) / (px * 0.5));
}

kernel void pkUpscaleKernel0(
    texture2d<float, access::read>  sourceY  [[texture(0)]],
    texture2d<float, access::read>  sourceUV [[texture(1)]],
    texture2d<float, access::write> destY    [[texture(2)]],
    texture2d<float, access::write> destUV   [[texture(3)]],
    constant UpscaleParams &params           [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.dstWidth || gid.y >= params.dstHeight) { return; }
    float2 srcPos = (float2(gid) + 0.5) * float2(float(params.srcWidth) / float(params.dstWidth),
                                                 float(params.srcHeight) / float(params.dstHeight)) - 0.5;
    // Luma: 4x4 Lanczos-2 neighbourhood.
    float sum = 0.0;
    float weightSum = 0.0;
    int baseX = int(floor(srcPos.x)) - 1;
    int baseY = int(floor(srcPos.y)) - 1;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            int sx = clamp(baseX + i, 0, int(params.srcWidth) - 1);
            int sy = clamp(baseY + j, 0, int(params.srcHeight) - 1);
            float w = lanczos2(srcPos.x - float(baseX + i)) * lanczos2(srcPos.y - float(baseY + j));
            sum += w * sourceY.read(uint2(uint(sx), uint(sy))).r;
            weightSum += w;
        }
    }
    float y = (weightSum != 0.0) ? (sum / weightSum) : sourceY.read(uint2(clamp(int(srcPos.x + 0.5), 0, int(params.srcWidth) - 1),
                                                                        clamp(int(srcPos.y + 0.5), 0, int(params.srcHeight) - 1))).r;
    destY.write(float4(clamp(y, 0.0, 1.0), 0.0, 0.0, 1.0), gid);
    if ((gid.x % 2) == 0 && (gid.y % 2) == 0) {
        uint2 sUV = uint2(min(uint(srcPos.x) / 2, params.srcWidth / 2 - 1),
                          min(uint(srcPos.y) / 2, params.srcHeight / 2 - 1));
        float2 uv = sourceUV.read(sUV).rg;
        destUV.write(float4(uv.x, uv.y, 0.0, 1.0), uint2(gid.x / 2, gid.y / 2));
    }
}

// MARK: - Frame interpolation (block-match motion + compensated blend)

struct MotionParams {
    uint width;       // full-res luma width
    uint height;      // full-res luma height
    uint block;       // block size in full-res pixels
    uint search;      // search radius in full-res pixels
};

kernel void pkMotionKernel0(
    texture2d<float, access::read>  prevY   [[texture(0)]],
    texture2d<float, access::read>  currY   [[texture(1)]],
    texture2d<float, access::write> motion  [[texture(2)]],
    constant MotionParams &params           [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) { return; }
    // One thread per block; gid is the block coordinate.
    uint bx = gid.x * params.block;
    uint by = gid.y * params.block;
    if (bx >= params.width || by >= params.height) { return; }
    float bestSAD = 1e30;
    int2 best = int2(0, 0);
    int r = int(params.search);
    for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
            float sad = 0.0;
            for (uint j = 0; j < params.block; j++) {
                for (uint i = 0; i < params.block; i++) {
                    uint2 a = uint2(min(bx + i, params.width - 1), min(by + j, params.height - 1));
                    int2 b = int2(int(a.x) + dx, int(a.y) + dy);
                    b = clamp(b, int2(0, 0), int2(int(params.width) - 1, int(params.height) - 1));
                    sad += abs(currY.read(a).r - prevY.read(uint2(b)).r);
                }
            }
            if (sad < bestSAD) {
                bestSAD = sad;
                best = int2(dx, dy);
            }
        }
    }
    // Confidence: normalise SAD per pixel; low confidence fades the
    // interpolation toward a plain cross-blend in pkInterpKernel0.
    float pixels = float(params.block * params.block);
    float confidence = clamp(1.0 - (bestSAD / pixels) * 8.0, 0.0, 1.0);
    motion.write(float4(float(best.x), float(best.y), confidence, 1.0), gid);
}

struct InterpParams {
    uint width;
    uint height;
    uint block;       // block size in full-res pixels
    float phase;      // 0.5 = midpoint frame
};

kernel void pkInterpKernel0(
    texture2d<float, access::read>  prevY   [[texture(0)]],
    texture2d<float, access::read>  currY   [[texture(1)]],
    texture2d<float, access::read>  motion  [[texture(2)]],
    texture2d<float, access::write> destY   [[texture(3)]],
    constant InterpParams &params           [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) { return; }
    uint2 blockCoord = uint2(gid.x / params.block, gid.y / params.block);
    float4 mv = motion.read(blockCoord);
    float2 offset = mv.rg * params.phase;
    int2 pPrev = clamp(int2(gid) - int2(offset), int2(0, 0),
                       int2(int(params.width) - 1, int(params.height) - 1));
    int2 pCurr = clamp(int2(gid) + int2(offset * (1.0 - params.phase) / max(params.phase, 0.001)),
                       int2(0, 0), int2(int(params.width) - 1, int(params.height) - 1));
    float a = prevY.read(uint2(pPrev)).r;
    float b = currY.read(uint2(pCurr)).r;
    float warped = mix(a, b, params.phase);
    float plain = mix(prevY.read(gid).r, currY.read(gid).r, params.phase);
    float y = mix(plain, warped, mv.b);
    destY.write(float4(y, 0.0, 0.0, 1.0), gid);
}

// NOTE (playback Dolby alignment, DOLBY-PLAYBACK.md): there is
// deliberately NO Dolby Vision kernel in this library.  The
// original's shipped metallib contains exactly one kernel — its
// SDR->HDR pkFrameKernel0 — and its playback path applies no
// per-frame Dolby pixel transform: DV frames are tagged and
// presented by the system compositor.  Profile 5 colour
// correction exists only on the still/screenshot path, on the
// CPU, in MPlayDolbyVision.swift (DolbyP5ColorCorrection, values
// extracted from the original — DOLBY-EXTRACTION.md).  An earlier
// build routed playback P5 frames through a GPU correction pass
// here (pkDoviP5Kernel0); that pass had no counterpart in the
// original's playback path and was removed.  (R-05 update: the
// compose_fel kernel appended below IS an original playback-path
// kernel — the fork's FEL dual-layer composition in its vo —
// extracted verbatim; it is not a P5 correction pass and only
// runs when an EL frame is actually supplied, see
// MPlayPostChain.runFELCompose.)

// MARK: - FEL composition (R-05, extracted verbatim)
//
// The compose_fel shader below is the original's own Metal source,
// extracted verbatim from the SenPlayer binary (file offset
// 0x4555c48, 4,952 bytes; archived at
// ~/workspace/p115-player-re/full-restoration/R-05-compose_fel.metal).
// Its hard-coded hpe matrix matches matrix A of
// DOLBY-EXTRACTION.md value for value.  The values must NOT be
// edited.  Only the extraction's first two lines (#include
// <metal_stdlib> / using namespace metal) are omitted here because
// this library file already carries them at its head; everything
// from `struct FELParams` onward is byte-identical to the
// extraction.  Driven by MPlayPostChain.runFELCompose with
// parameters packed by MPlayFELParams (MPlayFEL.swift).

struct FELParams { uint width; uint height; uint num_pivots[3]; float pivots[3][9]; uint method[3][8]; uint poly_order[3][8]; float poly_coef[3][8][3]; uint mmr_order[3][8]; float mmr_constant[3][8]; float mmr_coef[3][8][3][7]; float nlq_offset[3]; float nlq_slope[3]; float nlq_threshold[3]; float nonlinear_offset[3]; float nonlinear[9]; float linear[9]; };
float3 mul3(const device float *m, float3 v) { return float3(m[0]*v.x+m[1]*v.y+m[2]*v.z, m[3]*v.x+m[4]*v.y+m[5]*v.z, m[6]*v.x+m[7]*v.y+m[8]*v.z); }
float pq_eotf(float x) { constexpr float m1=0.1593017578125, m2=78.84375, c1=0.8359375, c2=18.8515625, c3=18.6875; x=pow(max(x,0.0f),1.0f/m2); return pow(max(x-c1,0.0f)/(c2-c3*x),1.0f/m1); }
float pq_oetf(float x) { constexpr float m1=0.1593017578125, m2=78.84375, c1=0.8359375, c2=18.8515625, c3=18.6875; x=pow(max(x,0.0f),m1); return pow((c1+c2*x)/(1.0f+c3*x),m2); }
float reshape(uint c, float3 sig, const device FELParams &p) { float s=sig[c]; uint piece=0; for (uint i=1; i+1<p.num_pivots[c]; i++) piece += s>=p.pivots[c][i]; if (p.method[c][piece]==0) { return clamp((p.poly_coef[c][piece][2]*s+p.poly_coef[c][piece][1])*s+p.poly_coef[c][piece][0],p.pivots[c][0],p.pivots[c][p.num_pivots[c]-1]); } float3 sig2=sig*sig; float4 cross=float4(sig.x*sig.y,sig.x*sig.z,sig.y*sig.z,sig.x*sig.y*sig.z); float4 cross2=cross*cross; float value=p.mmr_constant[c][piece]; for (uint order=0; order<p.mmr_order[c][piece]; order++) { float3 power=order==0?sig:(order==1?sig2:sig2*sig); float4 crossPower=order==0?cross:(order==1?cross2:cross2*cross); const device float *k=p.mmr_coef[c][piece][order]; value += dot(float3(k[0],k[1],k[2]),power)+dot(float4(k[3],k[4],k[5],k[6]),crossPower); } return clamp(value,p.pivots[c][0],p.pivots[c][p.num_pivots[c]-1]); }
float2 shifted(texture2d<float,access::sample> tex, float2 pos, float2 pixels) { return pos+pixels/float2(tex.get_width(),tex.get_height()); } float3 sample_bl(texture2d<float,access::sample> y, texture2d<float,access::sample> uv, sampler s, float2 pos) { constexpr float p010_to_code=65535.0f/65472.0f; return float3(y.sample(s,pos).r,uv.sample(s,shifted(uv,pos,float2(0.25f))).rg)*p010_to_code; } float3 sample_el(texture2d<float,access::sample> y, texture2d<float,access::sample> uv, sampler s, float2 pos) { constexpr float p010_to_code=65535.0f/65472.0f; return float3(y.sample(s,shifted(y,pos,float2(0.25f,0.0f))).r,uv.sample(s,shifted(uv,pos,float2(0.375f,0.25f))).rg)*p010_to_code; }
float3 compose(texture2d<float,access::sample> bly, texture2d<float,access::sample> bluv, texture2d<float,access::sample> ely, texture2d<float,access::sample> eluv, sampler s, float2 pos, const device FELParams &p) { float3 raw=sample_bl(bly,bluv,s,pos); float3 shaped=float3(reshape(0,raw,p),reshape(1,raw,p),reshape(2,raw,p)); float3 el=sample_el(ely,eluv,s,pos); float3 centered=el-float3(p.nlq_offset[0],p.nlq_offset[1],p.nlq_offset[2]); shaped += sign(centered)*(abs(centered)*float3(p.nlq_slope[0],p.nlq_slope[1],p.nlq_slope[2])+float3(p.nlq_threshold[0],p.nlq_threshold[1],p.nlq_threshold[2])); constexpr float offset_scale=1024.0f/1023.0f; float3 d=shaped-float3(p.nonlinear_offset[0],p.nonlinear_offset[1],p.nonlinear_offset[2])*offset_scale; float3 nonlinear=mul3(p.nonlinear,d); float3 linear=float3(pq_eotf(nonlinear.x),pq_eotf(nonlinear.y),pq_eotf(nonlinear.z)); linear=mul3(p.linear,linear); constexpr float hpe[9]={3.06441879,-2.16597676,0.10155818,-0.65612108,1.78554118,-0.12943749,0.01736321,-0.04725154,1.03004253}; linear=float3(hpe[0]*linear.x+hpe[1]*linear.y+hpe[2]*linear.z,hpe[3]*linear.x+hpe[4]*linear.y+hpe[5]*linear.z,hpe[6]*linear.x+hpe[7]*linear.y+hpe[8]*linear.z); return clamp(float3(pq_oetf(linear.x),pq_oetf(linear.y),pq_oetf(linear.z)),0.0f,1.0f); }
kernel void compose_fel(texture2d<float,access::sample> bly [[texture(0)]], texture2d<float,access::sample> bluv [[texture(1)]], texture2d<float,access::sample> ely [[texture(2)]], texture2d<float,access::sample> eluv [[texture(3)]], texture2d<float,access::write> outy [[texture(4)]], texture2d<float,access::write> outuv [[texture(5)]], const device FELParams &p [[buffer(0)]], uint2 block [[thread_position_in_grid]]) { uint2 base=block*2; if (base.x>=p.width||base.y>=p.height) return; constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear); constexpr float p010_max=1023.984375f; float2 size=float2(p.width,p.height); float3 rgb[4]; float yv[4]; for(uint i=0;i<4;i++){ uint2 q=base+uint2(i&1,i>>1); q=min(q,uint2(p.width-1,p.height-1)); rgb[i]=compose(bly,bluv,ely,eluv,s,(float2(q)+0.5f)/size,p); yv[i]=dot(rgb[i],float3(0.2627f,0.6780f,0.0593f)); outy.write(float4((64.0f+876.0f*yv[i])/p010_max),q); } float3 avg=(rgb[0]+rgb[1]+rgb[2]+rgb[3])*0.25f; float ya=(yv[0]+yv[1]+yv[2]+yv[3])*0.25f; float cb=(avg.b-ya)/1.8814f; float cr=(avg.r-ya)/1.4746f; outuv.write(float4((512.0f+896.0f*cb)/p010_max,(512.0f+896.0f*cr)/p010_max,0,1),block); }


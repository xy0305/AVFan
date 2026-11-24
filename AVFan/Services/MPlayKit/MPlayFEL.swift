//
//  MPlayFEL.swift
//  AVFan
//
//  Build 59 full restoration, R-05 (FEL dual-layer composition),
//  implementation wave 1 — the Swift-side components:
//
//  1. `MPlayFELParams`: a 1:1 packing of the extracted shader's
//     `FELParams` struct (R-05-compose_fel.metal, verbatim source
//     extracted from the original binary at file offset 0x4555c48)
//     filled from our RPU parser (`MPlayDoviRPU` in
//     MPlayDolbyVision.swift).  Field mapping follows the R-05
//     memo §5 component 2: reshaping pivots/method/poly/MMR come
//     from the RPU mapping segments, NLQ from the RPU NLQ segment,
//     and the DM matrices from the RPU colour-metadata block
//     (nonlinear <- yccToRGB, nonlinear_offset <- yccOffset,
//     linear <- rgbToLMS — the same assignment the extracted P5
//     convert chain uses, DOLBY-EXTRACTION.md §2; the shader's
//     hard-coded hpe matrix then matches matrix A there).
//
//  2. `MPlayDoviSplit`: a packet-level equivalent of the fork's
//     `dovi_split` bitstream filter (memo §1.1: four keep-modes
//     bl / bl_rpu / el / el_rpu), implemented as HEVC NAL-unit
//     classification + filtering in Swift.  This is NOT yet the
//     in-core BSF: it is the classification contract, usable by
//     host-side tooling/tests today and the reference the future
//     in-FFmpeg BSF must match.  It is labelled partial wherever
//     R-05 is reported.
//
//  SELF-DETERMINED values (NOT extracted original values — the
//  fork's C host is unsymbolled and was not disassembled, memo
//  §6.1; these must be calibrated against real P7 samples):
//   - Pivot normalisation: RPU pivots are divided by
//     (2^blBitDepth - 1).  The shader consumes normalised floats;
//     the fork's own scaling was not extracted.
//   - Polynomial coefficient order: coefficients are passed in
//     the parser's storage (wire) order into poly_coef slots
//     [0], [1], [2]; the shader evaluates
//     (coef[2]*s + coef[1])*s + coef[0].
//   - NLQ mapping: nlq_offset is the RPU offset normalised by
//     (2^elBitDepth - 1); for NLQ method LINEAR_DZ (1) slope /
//     threshold take the RPU linear-deadzone slope / threshold,
//     for method NONE (0) slope takes vdrInMax and threshold 0.
//     The fork's exact NLQ field assignment was not extracted.
//   - NAL classification table: RPU = HEVC unspecified NAL type
//     62, EL = type 63, parameter sets (VPS 32 / SPS 33 / PPS 34)
//     are kept with the EL in el/el_rpu modes so the EL stream
//     stays independently decodable.  The fork BSF's own table
//     details were not extracted (memo §6.1).
//

import Foundation

// MARK: - FELParams packing (component 2)

struct MPlayFELParams {
    var width: UInt32
    var height: UInt32
    /// [component][9] normalised pivot values; count per component
    /// is in `numPivots`.
    var numPivots: [UInt32]
    var pivots: [[Float]]
    /// Per component, per segment: 0 = polynomial, 1 = MMR.
    var method: [[UInt32]]
    var polyOrder: [[UInt32]]
    /// [component][segment][3]
    var polyCoef: [[[Float]]]
    var mmrOrder: [[UInt32]]
    var mmrConstant: [[Float]]
    /// [component][segment][order][7]
    var mmrCoef: [[[[Float]]]]
    var nlqOffset: [Float]
    var nlqSlope: [Float]
    var nlqThreshold: [Float]
    var nonlinearOffset: [Float]
    /// Row-major 3x3 (DM yccToRGB).
    var nonlinear: [Float]
    /// Row-major 3x3 (DM rgbToLMS).
    var linear: [Float]

    /// Build the parameter block for one frame from its parsed
    /// RPU.  Returns nil when the RPU lacks the pieces composition
    /// cannot run without (reshaping curves or DM metadata).
    static func make(rpu: MPlayDoviRPU, width: Int, height: Int) -> MPlayFELParams? {
        guard rpu.components.count == 3,
              let meta = rpu.colorMetadata else { return nil }
        let pivotScale = Float((1 << rpu.blBitDepth) - 1)
        let elScale = Float((1 << rpu.elBitDepth) - 1)

        var numPivots: [UInt32] = []
        var pivots: [[Float]] = []
        var method: [[UInt32]] = []
        var polyOrder: [[UInt32]] = []
        var polyCoef: [[[Float]]] = []
        var mmrOrder: [[UInt32]] = []
        var mmrConstant: [[Float]] = []
        var mmrCoef: [[[[Float]]]] = []

        for component in rpu.components {
            let curveCount = min(component.pivots.count, 9)
            numPivots.append(UInt32(curveCount))
            var row = [Float](repeating: 0, count: 9)
            for i in 0..<curveCount {
                row[i] = Float(component.pivots[i]) / pivotScale
            }
            pivots.append(row)

            var mRow = [UInt32](repeating: 0, count: 8)
            var poRow = [UInt32](repeating: 0, count: 8)
            var pcRow = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 8)
            var moRow = [UInt32](repeating: 0, count: 8)
            var mcRow = [Float](repeating: 0, count: 8)
            var mkRow = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: 7), count: 3), count: 8)
            for (segment, curve) in component.curves.prefix(8).enumerated() {
                switch curve {
                case .polynomial(let poly):
                    mRow[segment] = 0
                    poRow[segment] = UInt32(poly.order)
                    for (k, value) in poly.coefficients.prefix(3).enumerated() {
                        pcRow[segment][k] = Float(value)
                    }
                case .mmr(let mmr):
                    mRow[segment] = 1
                    moRow[segment] = UInt32(mmr.order)
                    mcRow[segment] = Float(mmr.constant)
                    for (order, coefs) in mmr.coefficients.prefix(3).enumerated() {
                        for (k, value) in coefs.prefix(7).enumerated() {
                            mkRow[segment][order][k] = Float(value)
                        }
                    }
                }
            }
            method.append(mRow)
            polyOrder.append(poRow)
            polyCoef.append(pcRow)
            mmrOrder.append(moRow)
            mmrConstant.append(mcRow)
            mmrCoef.append(mkRow)
        }

        var nlqOffset = [Float](repeating: 0, count: 3)
        var nlqSlope = [Float](repeating: 0, count: 3)
        var nlqThreshold = [Float](repeating: 0, count: 3)
        if rpu.nlqMethodIdc >= 0 {
            for (c, params) in rpu.nlq.prefix(3).enumerated() {
                nlqOffset[c] = Float(params.offset) / elScale
                if rpu.nlqMethodIdc == 1 {
                    nlqSlope[c] = Float(params.linearDeadzoneSlope)
                    nlqThreshold[c] = Float(params.linearDeadzoneThreshold)
                } else {
                    nlqSlope[c] = Float(params.vdrInMax)
                    nlqThreshold[c] = 0
                }
            }
        }

        let map = meta.map
        let nonlinear: [Float] = [
            Float(map.yccToRGB.m00), Float(map.yccToRGB.m01), Float(map.yccToRGB.m02),
            Float(map.yccToRGB.m10), Float(map.yccToRGB.m11), Float(map.yccToRGB.m12),
            Float(map.yccToRGB.m20), Float(map.yccToRGB.m21), Float(map.yccToRGB.m22),
        ]
        let linear: [Float] = [
            Float(map.rgbToLMS.m00), Float(map.rgbToLMS.m01), Float(map.rgbToLMS.m02),
            Float(map.rgbToLMS.m10), Float(map.rgbToLMS.m11), Float(map.rgbToLMS.m12),
            Float(map.rgbToLMS.m20), Float(map.rgbToLMS.m21), Float(map.rgbToLMS.m22),
        ]

        return MPlayFELParams(
            width: UInt32(width), height: UInt32(height),
            numPivots: numPivots, pivots: pivots,
            method: method, polyOrder: polyOrder, polyCoef: polyCoef,
            mmrOrder: mmrOrder, mmrConstant: mmrConstant, mmrCoef: mmrCoef,
            nlqOffset: nlqOffset, nlqSlope: nlqSlope, nlqThreshold: nlqThreshold,
            nonlinearOffset: [Float(map.yccOffset.x), Float(map.yccOffset.y), Float(map.yccOffset.z)],
            nonlinear: nonlinear, linear: linear)
    }

    /// Serialise into the exact byte layout of the shader's
    /// `FELParams` struct.  Every field in that struct is a 4-byte
    /// scalar or a contiguous array of them, so the Metal layout
    /// is the field order below with no padding.
    func metalBytes() -> Data {
        var data = Data()
        func u32(_ v: UInt32) { var x = v; data.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v; data.append(Data(bytes: &x, count: 4)) }
        u32(width); u32(height)
        for c in 0..<3 { u32(numPivots[c]) }
        for c in 0..<3 { for i in 0..<9 { f32(pivots[c][i]) } }
        for c in 0..<3 { for s in 0..<8 { u32(method[c][s]) } }
        for c in 0..<3 { for s in 0..<8 { u32(polyOrder[c][s]) } }
        for c in 0..<3 { for s in 0..<8 { for k in 0..<3 { f32(polyCoef[c][s][k]) } } }
        for c in 0..<3 { for s in 0..<8 { u32(mmrOrder[c][s]) } }
        for c in 0..<3 { for s in 0..<8 { f32(mmrConstant[c][s]) } }
        for c in 0..<3 { for s in 0..<8 { for o in 0..<3 { for k in 0..<7 { f32(mmrCoef[c][s][o][k]) } } } }
        for c in 0..<3 { f32(nlqOffset[c]) }
        for c in 0..<3 { f32(nlqSlope[c]) }
        for c in 0..<3 { f32(nlqThreshold[c]) }
        for c in 0..<3 { f32(nonlinearOffset[c]) }
        for k in 0..<9 { f32(nonlinear[k]) }
        for k in 0..<9 { f32(linear[k]) }
        return data
    }
}

// MARK: - dovi_split equivalent (component 3, packet level)

/// HEVC NAL-unit classification used by the split.  See the file
/// header for which parts are self-determined.
enum MPlayDoviNALKind {
    case baseLayer      // VCL and ordinary non-VCL units
    case parameterSet   // VPS (32) / SPS (33) / PPS (34)
    case rpu            // unspecified 62
    case enhancement    // unspecified 63
}

enum MPlayDoviSplit {
    enum Mode: String {
        case bl = "bl"
        case blRPU = "bl_rpu"
        case el = "el"
        case elRPU = "el_rpu"
    }

    static func classify(nalType: Int) -> MPlayDoviNALKind {
        switch nalType {
        case 62: return .rpu
        case 63: return .enhancement
        case 32, 33, 34: return .parameterSet
        default: return .baseLayer
        }
    }

    static func keeps(_ kind: MPlayDoviNALKind, mode: Mode) -> Bool {
        switch (kind, mode) {
        case (.baseLayer, .bl), (.baseLayer, .blRPU):
            return true
        case (.parameterSet, _):
            // Parameter sets travel with whichever layer stream
            // is being produced (self-determined, see header).
            return true
        case (.rpu, .blRPU), (.rpu, .elRPU):
            return true
        case (.enhancement, .el), (.enhancement, .elRPU):
            return true
        default:
            return false
        }
    }

    /// Filter one access unit's NAL units (type, payload) pairs
    /// down to what `mode` keeps, preserving order.
    static func filter(nalUnits: [(nalType: Int, data: Data)], mode: Mode) -> [(nalType: Int, data: Data)] {
        nalUnits.filter { keeps(classify(nalType: $0.nalType), mode: mode) }
    }
}

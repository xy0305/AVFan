//
//  MPlayCachePolicy.swift
//  AVFan
//
//  Build 59 full restoration, stage D: the cache policy model.
//
//  R-02 alignment (2026-11-24): the concrete values are NO LONGER
//  ours.  The original's CachePolicy defaults were extracted from
//  the SenPlayer 6.4.0 binary by disassembly
//  (~/workspace/p115-player-re/full-restoration/R-02-cachepolicy.md;
//  CachePolicy.init() @0x1018933e4 and the allocating init store the
//  same immediates, each field cross-checked against its variable
//  initialization expression):
//
//    capacity      Optional<UInt64> = nil   (no explicit cap)
//    directory     Optional<URL>    = nil   (no path literal)
//    segments      Int              = 8
//    segmentBytes  Int              = 0x200000  (2 MiB)
//    prefetchBytes Int              = 0x40000   (256 KiB)
//    seconds       Int              = 30
//    resolved      Bool (private)   = true
//
//  Derived (arithmetic, not a binary literal): the default
//  segmented window totals segments * segmentBytes = 16 MiB.
//
//  configure(capacity:directory:) branch semantics (same memo,
//  @0x10189348c):
//    capacity == nil -> directory is forced to nil (the argument
//                       is ignored), seconds = 30, resolved = true
//    capacity != nil -> capacity/directory stored as passed,
//                       seconds = 120, resolved = false (the 120
//                       is only an initial value: resolve() in the
//                       original recomputes seconds from duration /
//                       file size via an external helper whose
//                       formula was NOT extracted — see the memo
//                       §IV.3/§V.2 — so no recompute is implemented
//                       here and nothing is invented in its place)
//  Static preloadSeconds = 120 (getter @0x10142596c, measured).
//
//  options() effective-capacity constants (same memo §III.1,
//  @0x101893dc8-0x101893ddc): capacity nil or 0 -> 150 MiB
//  (0x9600000 = 157,286,400); non-zero .some -> 200 MiB
//  (0xC800000 = 209,715,200).  The constants and the csel are
//  measured; the reading "second slot = capacity effective in the
//  core" is the memo's INFERENCE (the values are consumed by an
//  external helper), so effectiveCapacity is exposed for
//  diagnostics only and is not forced onto any mpv option.
//
//  Mapping to mpv options: the only direct Swift-side mapping the
//  original makes is cache-secs <- seconds (restoreWindow /
//  updateWindow, memo §IV.1/§IV.2).  capacity / segments /
//  segmentBytes / prefetchBytes are handed to the core as a struct
//  for the original's own segmented model; they are NOT translated
//  into demuxer-max-bytes / demuxer-max-back-bytes, and the
//  original's defaultOptions contain no cache=yes / demuxer byte
//  caps at all (R-08 memo §I note 3).  Our previous self-chosen
//  values (384 MiB / 32 MiB / 4 MiB / 120 s and the mpv demuxer
//  mapping built on them) contradicted the original on every field
//  and are removed, not re-labelled.
//

import Foundation

struct MPlayCachePolicy {
    /// Total cache capacity in bytes; nil = no explicit cap
    /// (original: Optional<UInt64>, default nil).
    var capacity: UInt64?
    /// Cache directory; nil in the default policy (original:
    /// Optional<URL>, default nil, no path literal in the binary).
    var directory: URL?
    /// Segment count (original default: 8).
    var segments: Int
    /// Segment granularity in bytes (original default: 2 MiB).
    var segmentBytes: Int
    /// Read-ahead target per stream, in bytes (original default:
    /// 256 KiB).
    var prefetchBytes: Int
    /// Time-based cache window in seconds (original: Int, default
    /// 30; drives cache-secs).
    var seconds: Int
    /// Whether `seconds` is final (original private field, default
    /// true; configure() with a capacity clears it because the
    /// original then recomputes seconds in resolve()).
    private(set) var resolved: Bool

    /// The original's default policy, value for value (R-02 memo
    /// §I).  `standard` is kept as the name existing call sites use.
    static let standard = MPlayCachePolicy()

    /// Window seconds for the preload path (original static
    /// CachePolicy.preloadSeconds = 120, measured).
    static let preloadSeconds = 120

    init(capacity: UInt64? = nil,
         directory: URL? = nil,
         segments: Int = 8,
         segmentBytes: Int = 0x200000,
         prefetchBytes: Int = 0x40000,
         seconds: Int = 30,
         resolved: Bool = true) {
        self.capacity = capacity
        self.directory = directory
        self.segments = segments
        self.segmentBytes = segmentBytes
        self.prefetchBytes = prefetchBytes
        self.seconds = seconds
        self.resolved = resolved
    }

    /// Original configure(capacity:directory:) semantics (R-02
    /// memo §II): a nil capacity discards the directory argument
    /// and restores the 30 s / resolved state; a non-nil capacity
    /// stores both arguments and switches to the 120 s /
    /// unresolved state.
    mutating func configure(capacity: UInt64?, directory: URL?) {
        self.capacity = capacity
        if capacity == nil {
            self.directory = nil
            seconds = 30
            resolved = true
        } else {
            self.directory = directory
            seconds = 120
            resolved = false
        }
    }

    /// Effective capacity per the original options() constants
    /// (R-02 memo §III.1): nil or 0 -> 150 MiB, non-zero -> 200 MiB.
    /// Inference-level semantics (see header); diagnostics only.
    var effectiveCapacity: UInt64 {
        guard let capacity, capacity != 0 else { return 0x9600000 }
        return 0xC800000
    }

    /// mpv options derived from the policy.  The original's only
    /// direct mapping is cache-secs <- seconds; the segmented
    /// fields have no mpv-option counterpart on the Swift side
    /// (they fed the original's core-side segmented model through
    /// a helper whose internals were not extracted).
    var mpvOptions: [String: String] {
        ["cache-secs": "\(seconds)"]
    }
}

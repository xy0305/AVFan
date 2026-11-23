//
//  MPlayKernel.swift
//  AVFan
//
//  Build 59: AVFan is a hard kernel swap, not AVDB's dual-kernel switch:
//  MPlayKit (restored from ~/workspace/p115-player-re/RE-REPORT.md, libmpv
//  C API) is the ONLY playback kernel. This file is kept from the AVDB
//  port for shape parity, reduced to a single-case descriptor so no code
//  can select or fall back to the removed KSPlayer engine.
//

import Foundation

/// 播放内核。AVFan 只有一个内核；rawValue 是展示名，不要改名。
enum PlaybackKernel: String, CaseIterable, Identifiable {
    case mplayKit = "MPlayKit"
    var id: String { rawValue }
}

enum PlaybackKernelSettings {
    static let defaultsKey = "avfan.playback.kernel"
    /// 恒为 MPlayKit：AVFan 没有内核开关，旧版本写入的任何值都忽略。
    static var current: PlaybackKernel { .mplayKit }
}

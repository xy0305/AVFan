//
//  MPlayPreviewReader.swift
//  AVFan
//
//  Build 59: 对应原版 com.mplaykit.PreviewReader（RE 报告二.10：
//  n21–n26）——独立于播放实例的抓帧管线：一台自己的 mpv core，
//  seek 到目标时刻渲染一帧后读回 RGBA。渲染后端在全量还原阶段 A
//  由 GL（离屏 FBO + glReadPixels）换成 libmpv 的软件渲染 API
//  （MPV_RENDER_API_TYPE_SW）：主显示管线已关 GL（-Dgl=disabled），
//  render context 只能以 SW 形态创建；SW 渲染直接写进内存缓冲，
//  行序自上而下，不再需要翻行。原版 Still 的字段（宽/高/时刻/时长/
//  旋转/Dolby 档/是否封面图/RGBA/元数据）逐项保留；dolbyProfile 在
//  mpv 属性面没有对应物，恒为 nil（偏差表「未复刻的原版面」条）。
//
//  线程模型：全部状态只在自己的串行队列上变更；still/cancel/close
//  从任意线程调用都只是投递到队列。completion 在队列上回调，UI 侧
//  自行切回主线程。可取消：一台 reader 同一时刻只服务一个请求，
//  新请求会先取消旧请求；cancel() 让在途请求以失败完成。
//
//  本文件由协调者在收口阶段补写（Swift 层交付时漏了这个文件），
//  写法与 MPlayPlayer/MPlayVideoView 保持一致（回调形态、事件结构
//  读取、mpv_node 之外的标量属性读取均照同一套惯例）。
//

import Foundation
import Libmpv
import UIKit

/// 原版 PreviewReader$Still 的等价物。
struct MPlayStill {
    let width: Int
    let height: Int
    /// 抓帧时刻（秒，文件内实际落点）。
    let time: Double
    let duration: Double
    /// video-params/rotate；无旋转信息时 nil。
    let rotation: Int?
    /// mpv 属性面无逐帧 Dolby Vision profile 对应物，恒 nil（偏差表）。
    let dolbyProfile: String?
    /// 选中视频轨是图片轨（封面）时为 true。
    let cover: Bool
    /// RGBA8，行序自上而下（SW 渲染直接按图像方向输出）。
    let rgba: Data
    let metadata: [String: String]

    /// Still.jpeg() 的等价物：经 UIImage 转 JPEG。
    func jpegData(quality: Double = 0.85) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: bitmapInfo, provider: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: CGFloat(quality))
    }
}

/// 文件级 C 回调：mpv 唤醒（只转投 reader 的串行队列）。
private func mplayPreviewWakeupCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let reader = Unmanaged<MPlayPreviewReader>.fromOpaque(context).takeUnretainedValue()
    reader.handleWakeup()
}

/// 文件级 C 回调：render context 有新帧可画。
private func mplayPreviewRenderUpdateCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let reader = Unmanaged<MPlayPreviewReader>.fromOpaque(context).takeUnretainedValue()
    reader.handleFrameUpdate()
}

final class MPlayPreviewReader {

    private struct Pending {
        let generation: Int
        let targetSeconds: Double
        let maxWidth: Int
        let completion: (Result<MPlayStill, MPlayError>) -> Void
    }

    private let queue = DispatchQueue(label: "avfan.mplaykit.preview")
    private var closed = false
    private var generation = 0
    private var pending: Pending?
    private var timeoutItem: DispatchWorkItem?

    // 以下状态只在 queue 上访问。
    private var core: OpaquePointer?
    private var renderContextPointer: OpaquePointer?
    private var renderWidth: Int32 = 0
    private var renderHeight: Int32 = 0
    private var fileLoaded = false
    private var seekIssued = false

    init() {}

    // MARK: - 公共 API（任意线程可调用，内部投递到串行队列）

    /// 抓一帧静帧。hwdec 固定 no（抓帧可靠性优先，与播放实例的
    /// videotoolbox 分工不同，原版 PreviewReader 亦为独立管线）。
    func still(url: String, at seconds: Double, maxWidth: Int,
               headers: [String: String] = [:],
               completion: @escaping (Result<MPlayStill, MPlayError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.closed else {
                completion(.failure(.loadFailed("preview reader closed")))
                return
            }
            // 一台 reader 只服务一个在途请求：新请求先取消旧的。
            self.finishPending(.failure(.loadFailed("cancelled")))
            self.teardownCore()
            self.generation += 1
            let gen = self.generation
            self.pending = Pending(generation: gen, targetSeconds: seconds,
                                   maxWidth: max(1, maxWidth), completion: completion)
            self.fileLoaded = false
            self.seekIssued = false
            guard self.startCore(url: url, headers: headers, generation: gen) else {
                self.finishPending(.failure(.loadFailed("preview core create failed")))
                return
            }
            // 15 秒总超时（原版抓帧亦是短任务；超时即失败，不挂起）。
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.pending?.generation == gen else { return }
                self.finishPending(.failure(.loadFailed("preview timeout")))
                self.teardownCore()
            }
            self.timeoutItem = item
            self.queue.asyncAfter(deadline: .now() + 15, execute: item)
        }
    }

    /// 取消在途请求（以 loadFailed("cancelled") 完成它）。
    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.finishPending(.failure(.loadFailed("cancelled")))
            self.teardownCore()
        }
    }

    /// 关闭 reader；之后 still 一律失败。
    func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.finishPending(.failure(.loadFailed("cancelled")))
            self.teardownCore()
        }
    }

    // MARK: - 回调入口（文件级 C 函数转投）

    func handleWakeup() {
        queue.async { [weak self] in self?.handleEvents() }
    }

    func handleFrameUpdate() {
        queue.async { [weak self] in self?.attemptCapture() }
    }

    // MARK: - Core 生命周期（只在 queue 上）

    private func startCore(url: String, headers: [String: String], generation gen: Int) -> Bool {
        guard let handle = mpv_create() else { return false }
        core = handle
        let options: [String: String] = [
            "vo": "libmpv",
            "hwdec": "no",
            "pause": "yes",
            "cache": "no",
            "keep-open": "yes",
            "video-sync": "audio",
            "untimed": "yes",
            "hr-seek": "yes",
            "demuxer-max-bytes": "33554432",
            "msg-level": "all=warn",
        ]
        for (key, value) in options {
            _ = mpv_set_option_string(handle, key, value)
        }
        if !headers.isEmpty {
            // http-header-fields 的转义规则与 MPlayPlayer.open 一致。
            let fields = headers.map { key, value in
                "\(key): \(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,"))"
            }.joined(separator: ",")
            _ = mpv_set_option_string(handle, "http-header-fields", fields)
        }
        guard mpv_initialize(handle) == 0 else {
            mpv_terminate_destroy(handle)
            core = nil
            return false
        }
        mpv_set_wakeup_callback(handle, mplayPreviewWakeupCallback,
                                Unmanaged.passUnretained(self).toOpaque())
        let rc = command(handle, ["loadfile", url, "replace"])
        if rc < 0 {
            MPlayDiagnostics.log(level: 4, tag: "MPlayPreviewReader",
                                 "loadfile failed rc=\(rc) gen=\(gen)")
            teardownCore()
            return false
        }
        return true
    }

    private func teardownCore() {
        timeoutItem?.cancel()
        timeoutItem = nil
        if let renderContextPointer {
            mpv_render_context_set_update_callback(renderContextPointer, nil, nil)
            self.renderContextPointer = nil
            mpv_render_context_free(renderContextPointer)
        }
        renderWidth = 0
        renderHeight = 0
        if let core {
            mpv_set_wakeup_callback(core, nil, nil)
            mpv_terminate_destroy(core)
            self.core = nil
        }
        fileLoaded = false
        seekIssued = false
    }

    private func finishPending(_ result: Result<MPlayStill, MPlayError>) {
        guard let pending else { return }
        self.pending = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        pending.completion(result)
    }

    // MARK: - 事件（只在 queue 上）

    private func handleEvents() {
        guard let core else { return }
        while true {
            guard let eventPointer = mpv_wait_event(core, 0) else { return }
            let event = eventPointer.pointee
            if event.event_id == MPV_EVENT_NONE {
                return
            } else if event.event_id == MPV_EVENT_FILE_LOADED {
                fileLoaded = true
                prepareRenderTarget()
            } else if event.event_id == MPV_EVENT_END_FILE {
                if let data = event.data {
                    let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if endFile.reason == MPV_END_FILE_REASON_ERROR {
                        let message = String(cString: mpv_error_string(endFile.error))
                        finishPending(.failure(.loadFailed(message)))
                        teardownCore()
                        return
                    }
                }
            } else if event.event_id == MPV_EVENT_PLAYBACK_RESTART {
                attemptCapture()
            }
            // 其余事件忽略。
        }
    }

    /// FILE_LOADED 后：按显示尺寸（video-params/dw/dh，已含旋转与
    /// 宽高比）算抓帧尺寸，建 SW render context，并发一次精确 seek
    /// 到目标时刻（暂停态下 seek 后 core 会解出目标帧并触发
    /// PLAYBACK_RESTART / render update）。
    private func prepareRenderTarget() {
        guard let core, let pending else { return }
        let displayWidth = intProperty("video-params/dw") ?? intProperty("video-params/w") ?? 0
        let displayHeight = intProperty("video-params/dh") ?? intProperty("video-params/h") ?? 0
        guard displayWidth > 0, displayHeight > 0 else {
            finishPending(.failure(.loadFailed("preview: no video track")))
            teardownCore()
            return
        }
        var width = displayWidth
        var height = displayHeight
        if width > pending.maxWidth {
            height = max(1, Int((Double(height) * Double(pending.maxWidth) / Double(width)).rounded()))
            width = pending.maxWidth
        }
        let apiType = strdup(MPV_RENDER_API_TYPE_SW)
        defer { free(apiType) }
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                             data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        var newContext: OpaquePointer?
        let rc = mpv_render_context_create(&newContext, core, &params)
        guard rc == 0, let newContext else {
            finishPending(.failure(.loadFailed("preview: render context failed rc=\(rc)")))
            teardownCore()
            return
        }
        renderContextPointer = newContext
        mpv_render_context_set_update_callback(newContext, mplayPreviewRenderUpdateCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        renderWidth = Int32(width)
        renderHeight = Int32(height)
        if !seekIssued {
            seekIssued = true
            _ = command(core, ["seek", String(pending.targetSeconds), "absolute", "exact"])
        }
        attemptCapture()
    }

    /// 用 SW 渲染把当前帧写进内存缓冲并读回。FILE_LOADED 直后帧可能
    /// 还没解出——以 PLAYBACK_RESTART 与 render update 回调反复进入
    /// 本方法，直到渲染成功或超时收口。SW 输出的行序自上而下，
    /// 与 MPlayStill.rgba 的约定一致，无需翻行（方向正确性仍列入
    /// 真机首验清单：SW 后端按 dst_params 渲染，含旋转的源以
    /// video-params 的显示尺寸为目标，理论上已是正向画面）。
    private func attemptCapture() {
        guard let pending, fileLoaded,
              let renderContextPointer, renderWidth > 0, renderHeight > 0 else { return }
        let width = Int(renderWidth)
        let height = Int(renderHeight)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var size: [Int32] = [renderWidth, renderHeight]
        let format = strdup("rgba")
        defer { free(format) }
        // MPV_RENDER_PARAM_SW_STRIDE 的 C 侧类型是 size_t*
        // （libmpv_sw.c 实测），故用 Int（arm64 上与 size_t 同宽）。
        var stride = width * 4
        let rc = pixels.withUnsafeMutableBytes { buffer -> Int32 in
            var params: [mpv_render_param] = [
                mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: &size),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT,
                                 data: UnsafeMutableRawPointer(format)),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: &stride),
                mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buffer.baseAddress),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return mpv_render_context_render(renderContextPointer, &params)
        }
        guard rc == 0 else { return }
        let rgba = Data(pixels)
        let time = doubleProperty("time-pos") ?? pending.targetSeconds
        let duration = doubleProperty("duration") ?? 0
        let rotation = intProperty("video-params/rotate")
        let still = MPlayStill(width: width, height: height,
                               time: time, duration: duration,
                               rotation: rotation,
                               dolbyProfile: nil,
                               cover: selectedVideoTrackIsImage(),
                               rgba: rgba,
                               metadata: collectMetadata())
        MPlayDiagnostics.event(tag: "preview", "captured",
                               [("w", "\(width)"), ("h", "\(height)"), ("t", "\(time)")])
        finishPending(.success(still))
        teardownCore()
    }

    // MARK: - 属性读取小助手（只在 queue 上；读不到一律 nil）

    private func command(_ handle: OpaquePointer, _ args: [String]) -> Int32 {
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        defer { for pointer in cArgs { free(pointer) } }
        cArgs.append(nil)
        return cArgs.withUnsafeMutableBufferPointer { buffer in
            mpv_command(handle, buffer.baseAddress)
        }
    }

    private func stringProperty(_ name: String) -> String? {
        guard let core else { return nil }
        var value: UnsafeMutablePointer<CChar>?
        guard mpv_get_property(core, name, MPV_FORMAT_STRING, &value) == 0,
              let value else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func doubleProperty(_ name: String) -> Double? {
        guard let core else { return nil }
        var value: Double = 0
        guard mpv_get_property(core, name, MPV_FORMAT_DOUBLE, &value) == 0 else { return nil }
        return value
    }

    private func intProperty(_ name: String) -> Int? {
        guard let core else { return nil }
        var value: Int64 = 0
        guard mpv_get_property(core, name, MPV_FORMAT_INT64, &value) == 0 else { return nil }
        return Int(value)
    }

    private func flagProperty(_ name: String) -> Bool? {
        guard let core else { return nil }
        var value: Int32 = 0
        guard mpv_get_property(core, name, MPV_FORMAT_FLAG, &value) == 0 else { return nil }
        return value != 0
    }

    /// 选中视频轨的 image 标志（封面轨）——逐轨标量读取，与
    /// MPlayPlayer.mediaJSON 的做法一致。
    private func selectedVideoTrackIsImage() -> Bool {
        let count = intProperty("track-list/count") ?? 0
        for index in 0..<count {
            guard stringProperty("track-list/\(index)/type") == "video",
                  flagProperty("track-list/\(index)/selected") == true else { continue }
            return flagProperty("track-list/\(index)/image") ?? false
        }
        return false
    }

    private func collectMetadata() -> [String: String] {
        var metadata: [String: String] = [:]
        if let codec = stringProperty("video-codec") { metadata["videoCodec"] = codec }
        if let format = stringProperty("file-format") { metadata["container"] = format }
        if let title = stringProperty("media-title") { metadata["title"] = title }
        return metadata
    }
}

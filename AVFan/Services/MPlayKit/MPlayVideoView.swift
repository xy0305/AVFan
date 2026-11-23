//
//  MPlayVideoView.swift
//  AVFan
//
//  Build 59 full restoration, stage A: the display view of the
//  pixel-frame pipeline.  This replaces the GL implementation that
//  used to live here (libmpv render API + CAEAGLLayer) — that path
//  is retired and deleted, per the original's architecture
//  (IOS-FINDINGS §1/§3: the original builds mpv with -Dgl=disabled
//  and displays through a private frame_output vo feeding an
//  AVSampleBufferDisplayLayer; there is no GL anywhere in its main
//  display chain).
//
//  Shape (mirrors the original's FrameOutputView):
//  - The view's backing layer IS an AVSampleBufferDisplayLayer.
//  - Frames arrive from the player's frame_output vo through an
//    MPlayFrameSink registered under the player's sink name; the
//    FrameStore routes video frames to the FrameOutputScheduler
//    (which wraps them as CMSampleBuffers) and subtitle frames to
//    the independent subtitle layer.
//  - The subtitle layer is a sublayer of the display layer by
//    default — that is what lets sample-buffer PiP carry subtitles
//    with the picture — and can be reparented to an external host
//    view via moveSubtitleLayerToPictureInPictureHost(_:) /
//    moveSubtitleLayerToInlineHost() (the original's method names;
//    stage B drives them around PiP transitions).
//  - Time sync: the scheduler's control timebase is re-aligned from
//    the frame path (each enqueued frame nudges it when drift
//    exceeds a quarter second) and on explicit syncPlaybackTime
//    calls from the chrome's transport handling.
//

import AVFoundation
import CoreVideo
import Foundation
import QuartzCore
import UIKit

final class MPlayVideoView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    let frameStore = MPlayFrameStore()
    let subtitleLayerController = MPlaySubtitleLayerController()
    private(set) var scheduler: MPlayFrameOutputScheduler!

    /// Stage B: PiP controller bound to (player, view) on attach.
    let pictureInPictureController = MPlayPictureInPictureController()

    private var sink: MPlayFrameSink?
    private weak var attachedPlayer: MPlayPlayer?
    private var lastSyncedRate: Double = -1
    private var lastSyncHostTime: CFTimeInterval = 0

    /// Host view that receives the subtitle layer when it is moved
    /// out of the display layer (stage B: the PiP host).  Nil means
    /// the layer's external home is this view itself (an overlay
    /// above the display layer, same bounds).
    private weak var externalSubtitleHost: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scheduler = MPlayFrameOutputScheduler(displayLayer: displayLayer)
        scheduler.onLayerError = { [weak self] message in
            self?.attachedPlayer?.noteSurfaceError(message)
        }
        frameStore.onVideoFrame = { [weak self] frame in
            self?.scheduler.enqueue(frame)
            self?.nudgeTimeSync(with: frame)
        }
        frameStore.onSubtitleFrame = { [weak self] frame in
            self?.subtitleLayerController.update(frame)
        }
        subtitleLayerController.onRenderSizeChanged = { [weak self] size in
            self?.attachedPlayer?.setSubtitleRenderSize(
                width: Int(size.width), height: Int(size.height)
            )
        }
        // Default parent: the display layer itself (PiP-visible).
        displayLayer.addSublayer(subtitleLayerController.layer)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Attach / detach (contract kept from the GL view)

    /// Bind to a player: register the frame sink under the player's
    /// sink name so its frame_output vo starts delivering here.
    /// Idempotent for the same player; switching players detaches
    /// the old binding first.
    func attach(player: MPlayPlayer) {
        if attachedPlayer === player, sink != nil {
            return
        }
        detach()
        attachedPlayer = player
        let newSink = MPlayFrameSink(name: player.frameSinkName)
        newSink.onFrame = { [weak self] frame in
            self?.frameStore.update(frame)
        }
        newSink.register()
        sink = newSink
        // Initial subtitle render size follows the current bounds.
        subtitleLayerController.setRenderSize(bounds.size)
        player.setSubtitleRenderSize(
            width: Int(bounds.width), height: Int(bounds.height)
        )
        pictureInPictureController.bind(player: player, videoView: self)
    }

    /// Unbind: unregister the sink FIRST (the vo must stop calling
    /// into this view), then flush pending frames.  The player core
    /// itself is closed by the owner after detach, as before.
    /// PiP: the dismantle path defers detach() until PiP has stopped,
    /// so an active PiP is never torn down from here in the normal
    /// flow; if detach is called while PiP is active anyway (player
    /// switch), unbind stops PiP first.
    func detach() {
        pictureInPictureController.unbind()
        sink?.unregister()
        sink = nil
        scheduler.flush()
        frameStore.flush()
        subtitleLayerController.clear()
        attachedPlayer = nil
        lastSyncedRate = -1
    }

    // MARK: - Time sync

    /// Explicit re-sync from the chrome (transport events, seeks).
    func syncPlaybackTime(position: Double, rate: Double) {
        scheduler.syncPlaybackTime(position: position, rate: rate)
        lastSyncedRate = rate
        lastSyncHostTime = CACurrentMediaTime()
    }

    /// Per-frame drift control: re-align the timebase when the
    /// player's rate changed since the last sync, or when a second
    /// has passed (cheap drift correction without a separate timer).
    private func nudgeTimeSync(with frame: MPlayFrame) {
        guard let player = attachedPlayer, frame.ptsSeconds >= 0 else { return }
        let state = player.state()
        let rate = state.paused ? 0 : 1.0
        let now = CACurrentMediaTime()
        if rate != lastSyncedRate || now - lastSyncHostTime > 1.0 {
            scheduler.syncPlaybackTime(position: frame.ptsSeconds, rate: rate)
            lastSyncedRate = rate
            lastSyncHostTime = now
        }
    }

    // MARK: - Subtitle layer hosting (original: FrameOutputView)

    /// The view subtitles render into when the layer is not parented
    /// to the display layer.  Exposed for stage B (PiP host wiring).
    var subtitleLayer: CALayer {
        subtitleLayerController.layer
    }

    /// Move the subtitle layer into an external host view (PiP).
    /// The render size follows the host's bounds from here on.
    func moveSubtitleLayerToPictureInPictureHost(_ host: UIView) {
        externalSubtitleHost = host
        subtitleLayerController.layer.removeFromSuperlayer()
        host.layer.addSublayer(subtitleLayerController.layer)
        subtitleLayerController.layer.frame = host.bounds
        subtitleLayerController.setRenderSize(host.bounds.size)
    }

    /// Move the subtitle layer back to its inline home (the display
    /// layer) and restore the inline render size.
    func moveSubtitleLayerToInlineHost() {
        externalSubtitleHost = nil
        subtitleLayerController.layer.removeFromSuperlayer()
        displayLayer.addSublayer(subtitleLayerController.layer)
        subtitleLayerController.layer.frame = displayLayer.bounds
        subtitleLayerController.setRenderSize(bounds.size)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if externalSubtitleHost == nil {
            // Parented to the display layer: track its bounds.
            subtitleLayerController.layer.frame = displayLayer.bounds
            subtitleLayerController.setRenderSize(bounds.size)
        }
    }
}

//
//  DVLivePipeline.swift
//  DVLive
//
//  Ring drain → assemble → VT decode → bob deinterlace → callback.
//

import CoreMedia
import CoreVideo
import Foundation
import os.log

private let log = Logger(subsystem: "net.mrmidi.ASFW.DVLive", category: "Pipeline")

public final class DVLivePipeline: @unchecked Sendable {
    public typealias FrameHandler = (CVPixelBuffer, DVSystem, CMTime) -> Void

    private let client = DVDriverClient()
    private let assembler = DVFrameAssembler()
    private let decoder = DVDecoder()
    private let queue = DispatchQueue(label: "net.mrmidi.ASFW.DVLive.pipeline", qos: .userInteractive)

    private var ring: DVCaptureRing?
    private var timer: DispatchSourceTimer?
    private var handler: FrameHandler?
    private var frameIndex: Int64 = 0
    private var running = false
    private var syphon: SyphonOutput?
    private var speaker: DVAudioPlayer?
    private var lastAudioError: String?
    private var lastAudioMode: String?
    private var lastAspect: DVAspect?

    public private(set) var lastStats = DVCaptureStats()
    public private(set) var lastError: String?

    public init() {}

    public var isRunning: Bool { running }

    /// Start capture on channel (default 63). Handler called on pipeline queue.
    public func start(channel: UInt8 = 63, onFrame: @escaping FrameHandler) -> Bool {
        stop()
        lastError = nil
        handler = onFrame
        assembler.reset()
        frameIndex = 0
        lastAudioError = nil
        lastAudioMode = nil
        lastAspect = nil

        guard client.open() else {
            lastError = "ASFWDriver not available"
            return false
        }
        guard client.startDVCapture(channel: channel) else {
            lastError = "startDVCapture failed (IR busy or driver error)"
            client.close()
            return false
        }
        guard let mapped = client.mapDVCaptureRing() else {
            lastError = "Failed to map DV ring"
            client.stopDVCapture()
            client.close()
            return false
        }
        ring = mapped
        running = true
        syphon = SyphonOutput()

        // Poll faster than frame rate so we emit as soon as 300 DIF chunks arrive.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = t
        t.resume()
        log.info("DV live pipeline started on channel \(channel)")
        return true
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            _ = assembler.finish()
            ring?.unmap()
            ring = nil
            client.stopDVCapture()
            client.close()
            running = false
            handler = nil
            syphon?.stop()
            syphon = nil
            speaker?.stop()
            speaker = nil
            lastAudioError = nil
            lastAudioMode = nil
        }
        log.info("DV live pipeline stopped")
    }

    private func tick() {
        guard let ring else { return }
        ring.drain { chunk in
            if let frame = assembler.push(chunk) {
                emit(frame)
            }
        }
        lastStats = ring.stats
    }

    private func emit(_ frame: DVAssembledFrame) {
        playAudio(frame)
        do {
            let decoded = try decoder.decode(frame)
            let progressive = DVDeinterlacer.bobBottomField(decoded) ?? decoded
            let aspect = DVFrameGeometry.detect(in: frame.data, system: frame.system)
            DVFrameGeometry.setPixelAspect(of: progressive, aspect: aspect, system: frame.system)
            if aspect != lastAspect {
                lastAspect = aspect
                let size = DVFrameGeometry.displaySize(of: progressive, aspect: aspect, system: frame.system)
                log.notice("DV кадр: \(aspect.label, privacy: .public) → \(size.width, privacy: .public)×\(size.height, privacy: .public) квадратных пикселей")
            }
            syphon?.publish(progressive)
            let pts = CMTime(value: frameIndex, timescale: frame.system.frameRate)
            frameIndex += 1
            handler?(progressive, frame.system, pts)
        } catch {
            lastError = String(describing: error)
            log.error("Decode failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Квантизация и частота читаются из кадра. Смена AUDIO MODE на камере
    /// подхватывается со следующего кадра; плеер перестраивается, если сменилась частота.
    private func playAudio(_ frame: DVAssembledFrame) {
        do {
            let audio = try DVAudioExtractor.extract(frame.data)
            lastAudioError = nil
            if speaker == nil {
                speaker = DVAudioPlayer()
            }
            let bits = audio.format.quantization == 0 ? "16-bit" : "12-bit"
            let mode = "\(bits) \(audio.format.sampleRate)"
            if lastAudioMode != mode {
                lastAudioMode = mode
                log.info("DV audio live: \(mode, privacy: .public) Hz")
            }
            speaker?.enqueue(audio.samples, sampleRate: audio.format.sampleRate)
        } catch {
            let message = String(describing: error)
            if message != lastAudioError {
                lastAudioError = message
                log.error("DV audio: \(message, privacy: .public)")
            }
        }
    }
}

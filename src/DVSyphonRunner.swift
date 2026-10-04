//
//  DVSyphonRunner.swift — запуск живого DV-пайплайна в обход CMIO,
//  со сторожевым таймером: если поток встал, пайплайн перезапускается сам.
//  Кадры публикуются в Syphon внутри DVLivePipeline.emit().
//

import CoreVideo
import Foundation
import os.log

private let log = Logger(subsystem: "net.mrmidi.ASFW", category: "SyphonRunner")

@MainActor
final class DVSyphonRunner {
    static let shared = DVSyphonRunner()

    private let pipeline = DVLivePipeline()

    /// Пайплайн реально работает.
    private(set) var isRunning = false
    /// Пользователь хочет, чтобы он работал (переживает падения потока).
    private var wantRunning = false
    /// Сколько раз сторож перезапускал поток за сессию.
    private(set) var restartCount = 0

    private var channel: UInt8 = 63
    private var watchdog: Timer?
    private var lastPackets: UInt64 = 0
    private var lastProgress = Date()
    private var graceUntil = Date()
    private var retryAt = Date()

    /// Без новых DV-пакетов дольше этого — считаем поток вставшим.
    private let stallTimeout: TimeInterval = 5
    /// После перезапуска не трогаем поток, пока он раскачивается.
    private let graceInterval: TimeInterval = 8
    /// Пауза между неудачными попытками поднять пайплайн.
    private let retryInterval: TimeInterval = 3

    private init() {}

    // MARK: - Управление

    @discardableResult
    func start(channel: UInt8 = 63) -> Bool {
        guard !wantRunning else { return isRunning }
        self.channel = channel
        wantRunning = true
        let ok = startPipeline()
        startWatchdog()
        return ok
    }

    func stop() {
        wantRunning = false
        watchdog?.invalidate()
        watchdog = nil
        guard isRunning else { return }
        pipeline.stop()
        isRunning = false
        log.info("Syphon runner stopped (перезапусков за сессию: \(self.restartCount))")
    }

    var stats: DVCaptureStats { pipeline.lastStats }
    var lastError: String? { pipeline.lastError }

    // MARK: - Внутреннее

    @discardableResult
    private func startPipeline() -> Bool {
        let ok = pipeline.start(channel: channel) { _, _, _ in
            // Публикация в Syphon происходит внутри пайплайна.
        }
        let now = Date()
        if ok {
            isRunning = true
            lastPackets = 0
            lastProgress = now
            graceUntil = now.addingTimeInterval(graceInterval)
            log.info("Syphon runner started on channel \(self.channel)")
        } else {
            isRunning = false
            retryAt = now.addingTimeInterval(retryInterval)
            log.error("Syphon runner start failed: \(self.pipeline.lastError ?? "unknown", privacy: .public)")
        }
        return ok
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard wantRunning else { return }
        let now = Date()

        // Пайплайн не поднят — повторяем попытки с интервалом.
        guard isRunning else {
            if now >= retryAt {
                startPipeline()
            }
            return
        }

        // Считаем поток живым, пока растёт счётчик DV-пакетов.
        let packets = UInt64(pipeline.lastStats.dvSourcePackets)
        if packets != lastPackets {
            lastPackets = packets
            lastProgress = now
            return
        }

        guard now >= graceUntil else { return }
        guard now.timeIntervalSince(lastProgress) >= stallTimeout else { return }

        restart()
    }

    private func restart() {
        restartCount += 1
        log.notice("Поток встал — перезапуск #\(self.restartCount)")

        pipeline.stop()
        isRunning = false

        // Секунда на то, чтобы драйвер отпустил изохронный контекст.
        retryAt = Date().addingTimeInterval(1.0)
    }
}

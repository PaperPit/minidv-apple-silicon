//
//  DVAudioDiagnostics.swift
//  DVLive
//
//  Проверки звукового тракта без камеры и без FireWire:
//
//    --list-audio-devices                     что вообще есть в системе
//    --audio-selftest [сек]                   тон 1 кГц (L) / 3 кГц (R) в выбранное устройство
//    --dv-audio-selftest <файл.dv> [--pcm-out <файл>]
//                                             реальный .dv → DVAudioExtractor → плеер, в темпе 25 к/с
//    --audio-render-selftest <файл.dv> --pcm-out <файл>
//                                             тот же граф через AVAudioEngine в офлайн-рендере
//
//  Приёмник задаётся --audio-device (по умолчанию BlackHole 2ch). Первые две
//  проверки показывают, что звук доходит до устройства в реальном времени;
//  третья — что из кадра DV получается ровно тот PCM, что декодирует FFmpeg.
//

import AVFoundation
import CoreAudio
import Foundation

public enum DVAudioDiagnostics {

    /// Общий вход для headless-режимов приложения.
    public static func runAudioHeadless(arguments: [String]) -> Int32? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let next = arguments[index + 1]
            return next.hasPrefix("--") ? nil : next
        }
        func has(_ flag: String) -> Bool { arguments.contains(flag) }

        if has("--list-audio-devices") {
            print(CoreAudioDevices.describeAll())
            return 0
        }

        // Настройки ставит ASFWCommandLine до вызова; здесь только чтение.
        let device = DVAudioPlayer.isEnabled ? DVAudioPlayer.preferredDeviceQuery : nil

        if let path = value("--audio-render-selftest") {
            guard let out = value("--pcm-out") else {
                fputs("Использование: --audio-render-selftest <файл.dv> --pcm-out <файл.pcm>\n", stderr)
                return 2
            }
            return renderOffline(path: path, pcmOut: out)
        }

        if let path = value("--dv-audio-selftest") {
            return runDVFile(path: path,
                             device: device,
                             realtime: !has("--no-realtime"),
                             pcmOut: value("--pcm-out"))
        }

        if has("--audio-selftest") {
            let seconds = value("--audio-selftest").flatMap(Double.init) ?? 3.0
            return runTone(device: device, seconds: seconds)
        }

        return nil
    }

    // MARK: - Тон

    /// Гоняет тон через тот же DVAudioPlayer, что и живой звук.
    public static func runTone(device: String?, seconds: Double) -> Int32 {
        let rate = 48_000.0
        DVAudioPlayer.preferredDeviceQuery = device
        DVAudioPlayer.isEnabled = true
        let player = DVAudioPlayer()

        let chunkFrames = 960 // 20 мс
        let totalFrames = Int(seconds * rate)
        var written = 0
        var phaseL = 0.0
        var phaseR = 0.0
        let stepL = 2.0 * Double.pi * 1_000.0 / rate
        let stepR = 2.0 * Double.pi * 3_000.0 / rate

        print("[audio-selftest] приёмник: \(device ?? "системный выход"), \(Int(rate)) Гц, "
              + "\(seconds) с (1 кГц слева, 3 кГц справа)")

        while written < totalFrames {
            let frames = min(chunkFrames, totalFrames - written)
            var chunk = [Int16](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                chunk[frame * 2] = Int16((sin(phaseL) * 20_000).rounded())
                chunk[frame * 2 + 1] = Int16((sin(phaseR) * 20_000).rounded())
                phaseL += stepL
                phaseR += stepR
            }
            player.enqueue(chunk, sampleRate: rate)
            written += frames
            Thread.sleep(forTimeInterval: Double(frames) / rate)
        }

        Thread.sleep(forTimeInterval: 0.4)
        let stats = player.stats
        print("[audio-selftest] итог: \(stats.summary)")
        player.stop()
        return stats.framesPlayed > 0 ? 0 : 3
    }

    // MARK: - Реальный .dv

    /// Прогоняет файл через боевой путь (кадр → DVAudioExtractor → плеер) в темпе
    /// 25 кадров в секунду. `pcmOut` — дамп извлечённого PCM для сверки с FFmpeg.
    public static func runDVFile(path: String,
                                 device: String?,
                                 realtime: Bool = true,
                                 pcmOut: String? = nil) -> Int32 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            fputs("[dv-audio-selftest] не могу прочитать \(path)\n", stderr)
            return 2
        }
        let frameBytes = 144_000
        guard data.count >= frameBytes, data.count % frameBytes == 0 else {
            fputs("[dv-audio-selftest] размер \(data.count) не делится на \(frameBytes) (нужен PAL DV)\n", stderr)
            return 2
        }
        let frameCount = data.count / frameBytes
        print("[dv-audio-selftest] \(path): \(frameCount) кадров PAL, "
              + (realtime ? "реальное время" : "без задержек"))

        var player: DVAudioPlayer?
        if let device {
            DVAudioPlayer.preferredDeviceQuery = device
            DVAudioPlayer.isEnabled = true
            player = DVAudioPlayer()
            print("[dv-audio-selftest] приёмник: \(device.isEmpty ? "системный выход" : device)")
        } else {
            DVAudioPlayer.isEnabled = false
            print("[dv-audio-selftest] без вывода в устройство (разбор + дамп)")
        }

        var handle: FileHandle?
        if let pcmOut {
            FileManager.default.createFile(atPath: pcmOut, contents: nil)
            handle = FileHandle(forWritingAtPath: pcmOut)
        }
        defer { try? handle?.close() }

        var audioFrames = 0
        var audioErrors = 0
        var lastError: String?
        var samplesPerChannel = 0
        var rate = 0.0
        var quantization = -1

        for index in 0..<frameCount {
            let start = index * frameBytes
            let frame = data.subdata(in: start..<(start + frameBytes))
            do {
                let audio = try DVAudioExtractor.extract(frame)
                rate = audio.format.sampleRate
                quantization = audio.format.quantization
                samplesPerChannel += audio.format.samplesPerChannel
                player?.enqueue(audio.samples, sampleRate: audio.format.sampleRate)
                if let handle {
                    audio.samples.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        handle.write(Data(bytes: base, count: buffer.count * MemoryLayout<Int16>.size))
                    }
                }
                audioFrames += 1
            } catch {
                audioErrors += 1
                let text = String(describing: error)
                if lastError != text {
                    lastError = text
                    print("[dv-audio-selftest] кадр \(index): \(text)")
                }
            }

            if realtime {
                Thread.sleep(forTimeInterval: 1.0 / 25.0)
            }
            if (index + 1) % 25 == 0 {
                let played = player?.stats.framesPlayed ?? 0
                print(String(format: "[dv-audio-selftest] %.0f с: кадров %d (%d Гц, %@), сэмплов %d, проиграно %d, ошибок %d",
                             Double(index + 1) / 25.0, audioFrames, Int(rate),
                             quantization == 0 ? "16 бит" : "12 бит",
                             samplesPerChannel, played, audioErrors))
            }
        }

        if realtime { Thread.sleep(forTimeInterval: 0.4) }
        if let player {
            print("[dv-audio-selftest] итог плеера: \(player.stats.summary)")
            player.stop()
        }
        if let pcmOut { print("[dv-audio-selftest] PCM дамп: \(pcmOut) (\(samplesPerChannel) сэмплов на канал)") }
        return audioErrors == 0 ? 0 : 4
    }

    // MARK: - Офлайн-рендер графа

    /// Тот же путь, но вместо устройства — офлайн-рендер AVAudioEngine.
    /// Позволяет сверить PCM на выходе графа с эталоном FFmpeg побайтово.
    public static func renderOffline(path: String, pcmOut: String,
                                     chunkFrames: Int = 960) -> Int32 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            fputs("[audio-render-selftest] не могу прочитать \(path)\n", stderr)
            return 2
        }
        let frameBytes = 144_000
        guard data.count >= frameBytes, data.count % frameBytes == 0 else {
            fputs("[audio-render-selftest] размер \(data.count) не делится на \(frameBytes)\n", stderr)
            return 2
        }

        // 1. Разбор всех кадров — тот же вызов, что и в живом тракте.
        var pcm: [Int16] = []
        var rate = 0.0
        var channels = 2
        for index in 0..<(data.count / frameBytes) {
            let start = index * frameBytes
            do {
                let audio = try DVAudioExtractor.extract(data.subdata(in: start..<(start + frameBytes)))
                if rate == 0 { rate = audio.format.sampleRate }
                guard abs(rate - audio.format.sampleRate) < 0.5 else {
                    fputs("[audio-render-selftest] частота меняется внутри файла\n", stderr)
                    return 2
                }
                channels = audio.format.channels
                pcm.append(contentsOf: audio.samples)
            } catch {
                fputs("[audio-render-selftest] кадр \(index): \(String(describing: error))\n", stderr)
                return 4
            }
        }
        let totalFrames = pcm.count / channels
        print("[audio-render-selftest] \(totalFrames) сэмплов на канал, \(Int(rate)) Гц, \(channels) кан.")

        // 2. Граф, зеркальный живому: player → mixer, на входе тот же Int16.
        guard let dvFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: rate,
                                           channels: AVAudioChannelCount(channels),
                                           interleaved: true),
              let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: rate,
                                               channels: AVAudioChannelCount(channels),
                                               interleaved: false) else {
            fputs("[audio-render-selftest] не удалось создать формат\n", stderr)
            return 2
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: dvFormat)

        do {
            try engine.enableManualRenderingMode(.offline,
                                                 format: renderFormat,
                                                 maximumFrameCount: 4096)
            engine.prepare()
            try engine.start()
        } catch {
            fputs("[audio-render-selftest] граф не поднялся: \(error)\n", stderr)
            return 3
        }
        player.play()

        // 3. Отдаём PCM блоками, как это делает пайплайн на каждом кадре.
        var offset = 0
        while offset < pcm.count {
            let frames = min(chunkFrames, (pcm.count - offset) / channels)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: dvFormat,
                                                frameCapacity: AVAudioFrameCount(frames)),
                  let destination = buffer.int16ChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination.update(from: base + offset, count: frames * channels)
            }
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            offset += frames * channels
        }

        // 4. Рендер.
        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                  frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            fputs("[audio-render-selftest] нет буфера рендера\n", stderr)
            return 3
        }
        FileManager.default.createFile(atPath: pcmOut, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: pcmOut) else {
            fputs("[audio-render-selftest] не могу писать \(pcmOut)\n", stderr)
            return 2
        }
        defer { try? handle.close() }

        var rendered = 0
        while rendered < totalFrames {
            let want = AVAudioFrameCount(min(Int(engine.manualRenderingMaximumFrameCount),
                                             totalFrames - rendered))
            do {
                let status = try engine.renderOffline(want, to: renderBuffer)
                switch status {
                case .success:
                    guard let planes = renderBuffer.floatChannelData else { break }
                    let frames = Int(renderBuffer.frameLength)
                    let isInterleaved = engine.manualRenderingFormat.isInterleaved
                    var out = [Int16](repeating: 0, count: frames * channels)
                    for frame in 0..<frames {
                        for channelIndex in 0..<channels {
                            let raw = isInterleaved
                                ? planes[0][frame * channels + channelIndex]
                                : planes[channelIndex][frame]
                            let clamped = max(-1.0, min(1.0, Double(raw)))
                            out[frame * channels + channelIndex] = Int16((clamped * 32_767).rounded())
                        }
                    }
                    out.withUnsafeBufferPointer { buffer in
                        guard let base = buffer.baseAddress else { return }
                        handle.write(Data(bytes: base, count: buffer.count * MemoryLayout<Int16>.size))
                    }
                    rendered += frames
                case .cannotDoInCurrentContext, .insufficientDataFromInputNode:
                    continue
                default:
                    fputs("[audio-render-selftest] рендер прерван на \(rendered) сэмплах\n", stderr)
                    return 4
                }
            } catch {
                fputs("[audio-render-selftest] ошибка рендера: \(error)\n", stderr)
                return 4
            }
        }

        engine.stop()
        print("[audio-render-selftest] отрендерено \(rendered) сэмплов на канал → \(pcmOut)")
        return rendered == totalFrames ? 0 : 4
    }
}

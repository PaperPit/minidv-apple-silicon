//
//  DVAudioExtractor.swift — извлечение звука из сырого DV-кадра (PAL 625/50).
//  16 бит линейный и 12 бит нелинейный (две стереопары; наружу отдаётся первая,
//  на DCR-PC115E это микрофон). Раскладка как в libavformat/dv.c.
//  Выход: interleaved stereo Int16, готов для CoreAudio.
//

import AVFAudio
import Foundation

public struct DVAudioFormat: Equatable {
    public let sampleRate: Double
    /// 0 — 16 бит линейный, 1 — 12 бит нелинейный. Берётся из AAUX каждого кадра.
    public let quantization: Int
    public let channels: Int
    public let samplesPerChannel: Int
}

public enum DVAudioError: Error, CustomStringConvertible {
    case badFrameSize(Int)
    case noAudioSourcePack
    case unsupportedQuantization(Int)
    case unsupportedFrequency(Int)

    public var description: String {
        switch self {
        case .badFrameSize(let n):   return "Ожидался кадр PAL DV 144000 байт, получено \(n)"
        case .noAudioSourcePack:     return "AAUX Audio Source pack не найден"
        case .unsupportedQuantization(let q):
            return "Неизвестная квантизация \(q)"
        case .unsupportedFrequency(let f): return "Неизвестный код частоты \(f)"
        }
    }
}

public enum DVAudioExtractor {

    // Кадр = 12 DIF-последовательностей × 150 блоков × 80 байт.
    // В последовательности: 6 служебных блоков, далее 9 раз (1 аудио + 15 видео).
    private static let frameSize   = 144_000
    private static let blockSize   = 80
    private static let seqSize     = 150 * 80
    private static let seqCount    = 12
    private static let headerBlocks = 6
    private static let audioBlocks = 9
    private static let audioStride = 108

    private static let minSamples  = [1896, 1742, 1264]
    private static let frequencies: [Double] = [48000, 44100, 32000]
    private static let packOffset  = headerBlocks * blockSize + blockSize * 16 * 3 + 3

    // Таблица деshuffling PAL. Источник: FFmpeg, libavcodec/dv_profile.c
    private static let shuffle: [[Int]] = [
        [  0, 36,  72, 26, 62,  98, 16, 52,  88 ],
        [  6, 42,  78, 32, 68, 104, 22, 58,  94 ],
        [ 12, 48,  84,  2, 38,  74, 28, 64, 100 ],
        [ 18, 54,  90,  8, 44,  80, 34, 70, 106 ],
        [ 24, 60,  96, 14, 50,  86,  4, 40,  76 ],
        [ 30, 66, 102, 20, 56,  92, 10, 46,  82 ],
        [  1, 37,  73, 27, 63,  99, 17, 53,  89 ],
        [  7, 43,  79, 33, 69, 105, 23, 59,  95 ],
        [ 13, 49,  85,  3, 39,  75, 29, 65, 101 ],
        [ 19, 55,  91,  9, 45,  81, 35, 71, 107 ],
        [ 25, 61,  97, 15, 51,  87,  5, 41,  77 ],
        [ 31, 67, 103, 21, 57,  93, 11, 47,  83 ],
    ]

    public static func extract(_ frame: UnsafeRawBufferPointer) throws
        -> (format: DVAudioFormat, samples: [Int16]) {

        guard frame.count == frameSize else { throw DVAudioError.badFrameSize(frame.count) }
        let bytes = frame.bindMemory(to: UInt8.self)

        let p = packOffset
        guard bytes[p] == 0x50 else { throw DVAudioError.noAudioSourcePack }

        let smpls = Int(bytes[p + 1] & 0x3F)
        let freq  = Int((bytes[p + 4] >> 3) & 0x07)
        let quant = Int(bytes[p + 4] & 0x07)

        guard quant == 0 || quant == 1 else { throw DVAudioError.unsupportedQuantization(quant) }
        guard freq < frequencies.count else { throw DVAudioError.unsupportedFrequency(freq) }

        let samplesPerChannel = minSamples[freq] + smpls
        let slotCount = samplesPerChannel * 2
        var pcm = [Int16](repeating: 0, count: slotCount)

        if quant == 0 {
            decode16(bytes, into: &pcm, slotCount: slotCount)
        } else {
            decode12(bytes, into: &pcm, slotCount: slotCount)
        }

        return (DVAudioFormat(sampleRate: frequencies[freq],
                              quantization: quant,
                              channels: 2,
                              samplesPerChannel: samplesPerChannel), pcm)
    }

    /// 16 бит, big-endian. Каждая DIF-последовательность заполняет одну сторону пары.
    private static func decode16(_ bytes: UnsafeBufferPointer<UInt8>,
                                 into pcm: inout [Int16],
                                 slotCount: Int) {
        pcm.withUnsafeMutableBufferPointer { out in
            for seq in 0..<seqCount {
                var off = seq * seqSize + headerBlocks * blockSize
                for av in 0..<audioBlocks {
                    let base = shuffle[seq][av]
                    var d = 8
                    while d < blockSize {
                        let slot = base + ((d - 8) / 2) * audioStride
                        if slot < slotCount {
                            let raw = (UInt16(bytes[off + d]) << 8) | UInt16(bytes[off + d + 1])
                            out[slot] = (raw == 0x8000) ? 0 : Int16(bitPattern: raw)
                        }
                        d += 2
                    }
                    off += 16 * blockSize
                }
            }
        }
    }

    /// 12 бит нелинейный, 32 кГц. Первые 6 последовательностей — стереопара 1 (микрофон).
    private static func decode12(_ bytes: UnsafeBufferPointer<UInt8>,
                                 into pcm: inout [Int16],
                                 slotCount: Int) {
        let half = seqCount / 2
        pcm.withUnsafeMutableBufferPointer { out in
            for seq in 0..<half {
                var off = seq * seqSize + headerBlocks * blockSize
                for av in 0..<audioBlocks {
                    var d = 8
                    while d + 2 < blockSize {
                        let lc = (UInt16(bytes[off + d]) << 4) | (UInt16(bytes[off + d + 2]) >> 4)
                        let rc = (UInt16(bytes[off + d + 1]) << 4) | (UInt16(bytes[off + d + 2]) & 0x0f)
                        let step = (d - 8) / 3
                        let leftSlot = shuffle[seq][av] + step * audioStride
                        let rightSlot = shuffle[seq + half][av] + step * audioStride
                        if leftSlot < slotCount {
                            out[leftSlot] = (lc == 0x800) ? 0 : expand12(lc)
                        }
                        if rightSlot < slotCount {
                            out[rightSlot] = (rc == 0x800) ? 0 : expand12(rc)
                        }
                        d += 3
                    }
                    off += 16 * blockSize
                }
            }
        }
    }

    /// IEC 61834, нелинейные 12 бит → линейные 16. Та же арифметика, что dv_audio_12to16.
    private static func expand12(_ sample: UInt16) -> Int16 {
        let s = Int(sample < 0x800 ? sample : sample | 0xf000)
        var shift = (s & 0xf00) >> 8
        let result: Int
        if shift < 0x2 || shift > 0xd {
            result = s
        } else if shift < 0x8 {
            shift -= 1
            result = (s - 256 * shift) << shift
        } else {
            shift = 0xe - shift
            result = ((s + (256 * shift + 1)) << shift) - 1
        }
        return Int16(bitPattern: UInt16(truncatingIfNeeded: result))
    }

    public static func extract(_ frame: Data) throws
        -> (format: DVAudioFormat, samples: [Int16]) {
        try frame.withUnsafeBytes { try extract($0) }
    }
}

/// Проверочная запись WAV. Нужна только чтобы убедиться, что разбор верен.
public final class DVAudioWAVWriter {
    private let handle: FileHandle
    private let sampleRate: Double
    private var dataBytes: UInt32 = 0

    public init?(url: URL, sampleRate: Double) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = h
        self.sampleRate = sampleRate
        writeHeader(dataSize: 0)
    }

    public func append(_ samples: [Int16]) {
        samples.withUnsafeBufferPointer { buf in
            let d = Data(buffer: buf)
            handle.write(d)
            dataBytes += UInt32(d.count)
        }
    }

    public func finish() {
        try? handle.seek(toOffset: 0)
        writeHeader(dataSize: dataBytes)
        try? handle.close()
    }

    private func writeHeader(dataSize: UInt32) {
        var h = Data()
        func str(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }

        let ch: UInt16 = 2, bits: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(ch) * UInt32(bits / 8)

        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(ch)
        u32(UInt32(sampleRate)); u32(byteRate)
        u16(ch * bits / 8); u16(bits)
        str("data"); u32(dataSize)
        handle.write(h)
    }
}

/// Проигрывает стерео Int16 в устройство вывода по мере прихода кадров DV.
public final class DVAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var queued = 0
    private var generation = 0
    private let maxQueued = 6

    // Живой тракт: куда играть и что об этом известно.
    /// Приёмник звука с камеры. nil/""/"default" — системный выход.
    /// По умолчанию BlackHole: тогда любое приложение видит его как микрофон.
    public static var preferredDeviceQuery: String? = "BlackHole 2ch"
    /// Полный выключатель звуковой ветки.
    public static var isEnabled = true

    public private(set) var deviceName: String?
    private var statsStorage = DVAudioPlayerStats()

    /// Счётчики для диагностики живого тракта.
    public var stats: DVAudioPlayerStats {
        lock.lock(); defer { lock.unlock() }
        var snapshot = statsStorage
        snapshot.deviceName = deviceName
        return snapshot
    }

    public init() {
        engine.attach(player)
    }

    public func enqueue(_ samples: [Int16], sampleRate: Double) {
        guard Self.isEnabled, !samples.isEmpty, samples.count % 2 == 0 else { return }

        lock.lock()
        let rateChanged = format?.sampleRate != sampleRate
        let tooDeep = !rateChanged && queued >= maxQueued
        lock.unlock()
        guard !tooDeep else {
            lock.lock()
            statsStorage.droppedBuffers += 1
            lock.unlock()
            return
        }

        if rateChanged {
            guard startEngine(sampleRate: sampleRate) else { return }
        }
        guard let format else { return }

        let frames = AVAudioFrameCount(samples.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)[0]
            .mData?
            .assumingMemoryBound(to: Int16.self)
        guard let dst else { return }
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: samples.count)
        }

        lock.lock()
        let token = generation
        queued += 1
        statsStorage.buffersScheduled += 1
        statsStorage.framesScheduled += samples.count / 2
        lock.unlock()

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if token == self.generation {
                self.queued = max(0, self.queued - 1)
                self.statsStorage.buffersPlayed += 1
                self.statsStorage.framesPlayed += Int(frames)
            }
            self.lock.unlock()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    public func stop() {
        player.stop()
        engine.stop()
        lock.lock()
        format = nil
        queued = 0
        generation += 1
        lock.unlock()
    }

    /// Новая частота (смена AUDIO MODE) — пересобрать граф. Вызывать без lock.
    private func startEngine(sampleRate: Double) -> Bool {
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: sampleRate,
                                      channels: 2,
                                      interleaved: true) else { return false }
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        if let routed = DVAudioRouting.attach(engine: engine, query: Self.preferredDeviceQuery) {
            lock.lock()
            deviceName = routed
            lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            lock.lock()
            format = nil
            generation += 1
            lock.unlock()
            return false
        }
        lock.lock()
        format = fmt
        queued = 0
        generation += 1
        lock.unlock()
        return true
    }
}

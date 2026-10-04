//
//  DVAudioSupport.swift
//  DVLive
//
//  Опора для живого звука: перечисление устройств CoreAudio, выбор приёмника
//  для графа DVAudioPlayer и счётчики для диагностики.
//
//  Зачем выбор устройства: по умолчанию AVAudioEngine играет в системный выход.
//  Чтобы звук с камкордера попал в микрофон приложения (OBS/Zoom), его надо
//  адресно отдать в виртуальное устройство (BlackHole и подобные), не меняя
//  системный вывод — иначе звук перестанет быть слышен в других приложениях.
//

import AVFoundation
import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "net.mrmidi.ASFW.DVLive", category: "AudioSupport")

// MARK: - Статистика плеера

public struct DVAudioPlayerStats: Sendable {
    public var buffersScheduled = 0
    public var buffersPlayed = 0
    public var framesScheduled = 0
    public var framesPlayed = 0
    public var droppedBuffers = 0
    public var deviceName: String?

    public var summary: String {
        "буферов отдано \(buffersScheduled), проиграно \(buffersPlayed), "
            + "сэмплов \(framesPlayed)/\(framesScheduled), отброшено \(droppedBuffers)"
            + (deviceName.map { ", устройство «\($0)»" } ?? "")
    }
}

// MARK: - Устройства CoreAudio

public struct CoreAudioDeviceInfo: Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let outputChannels: Int
    public let inputChannels: Int
    public let nominalSampleRate: Double

    public var hasOutput: Bool { outputChannels > 0 }
    public var hasInput: Bool { inputChannels > 0 }
}

public enum CoreAudioDevices {

    public static func all() -> [CoreAudioDeviceInfo] {
        deviceIDs()
            .map { info(for: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Системный выход по умолчанию.
    public static func defaultOutputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return nil }
        return id
    }

    /// Поиск выходного устройства: точный UID → точное имя → подстрока.
    /// nil / "" / "default" → системный выход. Если запрошенное устройство
    /// не найдено, возвращается системный выход (и об этом пишется в лог).
    public static func resolve(query: String?) -> CoreAudioDeviceInfo? {
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let outputs = all().filter(\.hasOutput)

        if trimmed.isEmpty || trimmed.lowercased() == "default" {
            guard let id = defaultOutputID() else { return outputs.first }
            return info(for: id)
        }

        let lower = trimmed.lowercased()
        if let exact = outputs.first(where: {
            $0.uid.lowercased() == lower || $0.name.lowercased() == lower
        }) {
            return exact
        }
        if let partial = outputs.first(where: {
            $0.uid.lowercased().contains(lower) || $0.name.lowercased().contains(lower)
        }) {
            return partial
        }

        log.error("Аудиоустройство «\(trimmed, privacy: .public)» не найдено — играю в системный выход")
        return resolve(query: nil)
    }

    public static func info(for id: AudioDeviceID) -> CoreAudioDeviceInfo {
        CoreAudioDeviceInfo(
            id: id,
            name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
            uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            nominalSampleRate: nominalSampleRate(id) ?? 0
        )
    }

    /// Список для `--list-audio-devices`.
    public static func describeAll() -> String {
        let defaultID = defaultOutputID()
        var lines = ["Устройства CoreAudio (id | имя | out/in | Гц | uid):"]
        for device in all() {
            let mark = device.id == defaultID ? "  ← системный выход" : ""
            lines.append(String(format: "  %-4u %@  out:%d in:%d  %.0f Гц  %@%@",
                                device.id, device.name, device.outputChannels,
                                device.inputChannels, device.nominalSampleRate,
                                device.uid, mark))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func channelCount(_ id: AudioDeviceID,
                                     scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }
}

// MARK: - Привязка графа к устройству

public enum DVAudioRouting {

    /// Направляет выход графа в выбранное устройство. Возвращает имя устройства,
    /// к которому привязались (даже если привязка не удалась — тогда системный выход).
    @discardableResult
    public static func attach(engine: AVAudioEngine, query: String?) -> String? {
        guard let device = CoreAudioDevices.resolve(query: query) else {
            log.error("В системе нет устройств вывода — звук с камеры некуда играть")
            return nil
        }
        guard let unit = engine.outputNode.audioUnit else { return device.name }

        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            log.error("Не удалось переключить вывод на «\(device.name, privacy: .public)»: OSStatus \(status)")
        } else {
            log.info("DV audio → «\(device.name, privacy: .public)» (\(device.uid, privacy: .public))")
        }
        return device.name
    }
}

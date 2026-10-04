//
//  DVFrameAssembler.swift
//  DVLive
//
//  Assembles 480-byte DIF chunks into exact-size DV frames (PAL/NTSC).
//

import Foundation

public enum DVSystem: Sendable {
    case pal
    case ntsc

    public var frameBytes: Int {
        switch self {
        case .pal: return 144_000
        case .ntsc: return 120_000
        }
    }

    public var width: Int32 { 720 }

    public var height: Int32 {
        switch self {
        case .pal: return 576
        case .ntsc: return 480
        }
    }

    public var frameRate: Int32 {
        switch self {
        case .pal: return 25
        case .ntsc: return 30
        }
    }

    public var label: String {
        switch self {
        case .pal: return "PAL (625/50)"
        case .ntsc: return "NTSC (525/60)"
        }
    }
}

public struct DVAssembledFrame: Sendable {
    public let data: Data
    public let system: DVSystem
}

/// DIF chunk → complete DV frame. Only exact-size frames are emitted.
public final class DVFrameAssembler: @unchecked Sendable {
    private var currentFrame = Data()
    private var inFrame = false
    private var expectedBytes = 120_000
    private(set) public var system: DVSystem?
    public private(set) var framesEmitted = 0
    public private(set) var framesDropped = 0

    public init() {}

    public func reset() {
        currentFrame.removeAll(keepingCapacity: true)
        inFrame = false
        system = nil
        framesEmitted = 0
        framesDropped = 0
    }

    /// Feed one 480-byte DIF chunk. Returns a frame when a complete one is ready.
    public func push(_ chunk: UnsafeRawBufferPointer) -> DVAssembledFrame? {
        guard chunk.count == 480 else { return nil }

        let b0 = chunk[0]
        let b1 = chunk[1]
        let b3 = chunk[3]
        let isFrameStart = (b0 & 0xE0) == 0x00 && (b1 & 0xFC) == 0x04

        var completed: DVAssembledFrame?

        if isFrameStart {
            completed = flushCurrentFrame()
            inFrame = true
            let isPAL = (b3 & 0x80) != 0
            let sys: DVSystem = isPAL ? .pal : .ntsc
            system = sys
            expectedBytes = sys.frameBytes
            currentFrame.removeAll(keepingCapacity: true)
        }

        guard inFrame else { return completed }
        currentFrame.append(contentsOf: chunk)
        return completed
    }

    public func finish() -> DVAssembledFrame? {
        flushCurrentFrame()
    }

    private func flushCurrentFrame() -> DVAssembledFrame? {
        guard inFrame, !currentFrame.isEmpty else { return nil }
        defer {
            currentFrame.removeAll(keepingCapacity: true)
            inFrame = false
        }
        guard let sys = system, currentFrame.count == expectedBytes else {
            framesDropped += 1
            return nil
        }
        framesEmitted += 1
        return DVAssembledFrame(data: currentFrame, system: sys)
    }
}

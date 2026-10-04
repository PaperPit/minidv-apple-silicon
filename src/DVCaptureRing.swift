//
//  DVCaptureRing.swift
//  DVLive
//
//  Consumer-side view of the shared DV DIF ring (ABI with
//  ASFWDriver/Isoch/Receive/DVCaptureSink.hpp).
//

import Foundation
import IOKit

public struct DVCaptureStats: Sendable {
    public var packetsSeen: UInt32 = 0
    public var dvSourcePackets: UInt32 = 0
    public var nonDvPackets: UInt32 = 0
    public var overruns: UInt32 = 0
    public var lastRejectLen: UInt32 = 0
    public var lastRejectQ0: UInt32 = 0
    public var lastRejectQ1: UInt32 = 0
    public var lastXferStatus: UInt32 = 0

    public init(
        packetsSeen: UInt32 = 0,
        dvSourcePackets: UInt32 = 0,
        nonDvPackets: UInt32 = 0,
        overruns: UInt32 = 0,
        lastRejectLen: UInt32 = 0,
        lastRejectQ0: UInt32 = 0,
        lastRejectQ1: UInt32 = 0,
        lastXferStatus: UInt32 = 0
    ) {
        self.packetsSeen = packetsSeen
        self.dvSourcePackets = dvSourcePackets
        self.nonDvPackets = nonDvPackets
        self.overruns = overruns
        self.lastRejectLen = lastRejectLen
        self.lastRejectQ0 = lastRejectQ0
        self.lastRejectQ1 = lastRejectQ1
        self.lastXferStatus = lastXferStatus
    }
}

/// Single-consumer mapped view of the driver DV ring (memory type 1).
public final class DVCaptureRing: @unchecked Sendable {
    public static let magic: UInt32 = 0x4153_4456 // 'ASDV'
    public static let recordBytes = 480

    private let base: UnsafeMutableRawPointer
    private let mappedAddress: mach_vm_address_t
    private let connection: io_connect_t
    private let numRecords: UInt32
    private let dataOffset: Int

    private init(base: UnsafeMutableRawPointer,
                 mappedAddress: mach_vm_address_t,
                 connection: io_connect_t,
                 numRecords: UInt32,
                 dataOffset: Int) {
        self.base = base
        self.mappedAddress = mappedAddress
        self.connection = connection
        self.numRecords = numRecords
        self.dataOffset = dataOffset
    }

    public static func map(connection: io_connect_t) -> DVCaptureRing? {
        var address: mach_vm_address_t = 0
        var length: mach_vm_size_t = 0
        let options = UInt32(kIOMapAnywhere | kIOMapDefaultCache)
        let kr = IOConnectMapMemory64(connection, 1, mach_task_self_, &address, &length, options)
        guard kr == KERN_SUCCESS, let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)) else {
            return nil
        }

        let magic = pointer.load(fromByteOffset: 0, as: UInt32.self)
        let numRecords = pointer.load(fromByteOffset: 8, as: UInt32.self)
        let recBytes = pointer.load(fromByteOffset: 12, as: UInt32.self)
        let dataOffset = pointer.load(fromByteOffset: 16, as: UInt32.self)

        guard magic == DVCaptureRing.magic,
              recBytes == UInt32(DVCaptureRing.recordBytes),
              numRecords > 0,
              UInt64(dataOffset) + UInt64(numRecords) * UInt64(recBytes) <= UInt64(length) else {
            IOConnectUnmapMemory64(connection, 1, mach_task_self_, address)
            return nil
        }

        return DVCaptureRing(base: pointer,
                             mappedAddress: address,
                             connection: connection,
                             numRecords: numRecords,
                             dataOffset: Int(dataOffset))
    }

    public func unmap() {
        IOConnectUnmapMemory64(connection, 1, mach_task_self_, mappedAddress)
    }

    @discardableResult
    public func drain(_ handler: (UnsafeRawBufferPointer) -> Void) -> Int {
        let w = base.load(fromByteOffset: 64, as: UInt32.self)
        var r = base.load(fromByteOffset: 128, as: UInt32.self)
        var consumed = 0

        while r != w {
            let idx = Int(r % numRecords)
            let chunk = UnsafeRawBufferPointer(
                start: base + dataOffset + idx * DVCaptureRing.recordBytes,
                count: DVCaptureRing.recordBytes
            )
            handler(chunk)
            r &+= 1
            consumed += 1
        }

        if consumed > 0 {
            base.storeBytes(of: r, toByteOffset: 128, as: UInt32.self)
        }
        return consumed
    }

    public var stats: DVCaptureStats {
        DVCaptureStats(
            packetsSeen: base.load(fromByteOffset: 24, as: UInt32.self),
            dvSourcePackets: base.load(fromByteOffset: 28, as: UInt32.self),
            nonDvPackets: base.load(fromByteOffset: 32, as: UInt32.self),
            overruns: base.load(fromByteOffset: 36, as: UInt32.self),
            lastRejectLen: base.load(fromByteOffset: 40, as: UInt32.self),
            lastRejectQ0: base.load(fromByteOffset: 44, as: UInt32.self),
            lastRejectQ1: base.load(fromByteOffset: 48, as: UInt32.self),
            lastXferStatus: base.load(fromByteOffset: 52, as: UInt32.self)
        )
    }
}

//
//  DVDriverClient.swift
//  DVLive
//
//  Minimal IOKit client: open ASFWDriver, Start/Stop DV capture, map ring.
//

import Foundation
import IOKit
import os.log

private let log = Logger(subsystem: "net.mrmidi.ASFW.DVLive", category: "DriverClient")

public final class DVDriverClient: @unchecked Sendable {
    public enum Method: UInt32 {
        case startDVCapture = 50
        case stopDVCapture = 51
    }

    private var connection: io_connect_t = 0
    private let serviceName = "ASFWDriver"

    public init() {}

    deinit {
        close()
    }

    public var isOpen: Bool { connection != 0 }

    @discardableResult
    public func open() -> Bool {
        if connection != 0 { return true }

        let matching = IOServiceNameMatching(serviceName)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            log.error("ASFWDriver service not found")
            return false
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else {
            log.error("IOServiceOpen failed: 0x\(String(kr, radix: 16))")
            return false
        }
        connection = conn
        log.info("Opened ASFWDriver user client")
        return true
    }

    public func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    public func startDVCapture(channel: UInt8 = 63) -> Bool {
        guard connection != 0 else { return false }
        var input: [UInt64] = [UInt64(channel)]
        let kr = IOConnectCallScalarMethod(
            connection,
            Method.startDVCapture.rawValue,
            &input, 1,
            nil, nil
        )
        if kr != KERN_SUCCESS {
            log.error("startDVCapture failed: 0x\(String(kr, radix: 16))")
            return false
        }
        return true
    }

    public func stopDVCapture() {
        guard connection != 0 else { return }
        _ = IOConnectCallScalarMethod(
            connection,
            Method.stopDVCapture.rawValue,
            nil, 0,
            nil, nil
        )
    }

    public func mapDVCaptureRing() -> DVCaptureRing? {
        guard connection != 0 else { return nil }
        return DVCaptureRing.map(connection: connection)
    }
}

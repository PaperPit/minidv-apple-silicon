//
//  DVDeinterlacer.swift
//  DVLive
//
//  Bob deinterlace: keep bottom field (PAL BFF), double lines → progressive.
//

import CoreVideo
import Foundation

public enum DVDeinterlacer {
    /// Bob from interlaced BGRA: take odd rows (bottom field first) and stretch 2× vertically.
    public static func bobBottomField(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(source)
        guard let srcBase = CVPixelBufferGetBaseAddress(source), height >= 2 else { return nil }

        var dest: CVPixelBuffer?
        let attrs: NSDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &dest
        )
        guard status == kCVReturnSuccess, let dest else { return nil }

        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }
        guard let dstBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dest)

        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)
        let copyWidth = min(bytesPerRow, dstBytesPerRow, width * 4)

        // Bottom-field-first: field 0 occupies odd lines (1,3,5,...) in progressive layout
        // of many DV decoders; for VT BGRA we treat odd-indexed rows as the bottom field.
        for y in 0..<height {
            let srcRow = (y | 1)
            let clamped = min(srcRow, height - 1)
            let srcLine = src.advanced(by: clamped * bytesPerRow)
            let dstLine = dst.advanced(by: y * dstBytesPerRow)
            dstLine.update(from: srcLine, count: copyWidth)
        }
        return dest
    }
}

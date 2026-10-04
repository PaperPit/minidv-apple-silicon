//
//  DVDecoder.swift
//  DVLive
//
//  Decode a raw DV frame (IEC 61883-2) to CVPixelBuffer via VideoToolbox.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class DVDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var currentSystem: DVSystem?
    private let outputPixelFormat = kCVPixelFormatType_32BGRA

    public enum DecoderError: Error {
        case formatDescription
        case sessionCreate(OSStatus)
        case sampleBuffer(OSStatus)
        case decode(OSStatus)
        case noImageBuffer
    }

    public init() {}

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    public func decode(_ frame: DVAssembledFrame) throws -> CVPixelBuffer {
        try ensureSession(for: frame.system)

        let byteCount = frame.data.count
        var owned: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &owned
        )
        guard status == noErr, let owned else {
            throw DecoderError.sampleBuffer(status)
        }
        status = frame.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: owned,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == noErr else { throw DecoderError.sampleBuffer(status) }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: frame.system.frameRate),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = byteCount
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: owned,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DecoderError.sampleBuffer(status)
        }

        var imageBuffer: CVPixelBuffer?
        var decodeStatus: OSStatus = noErr

        status = VTDecompressionSessionDecodeFrame(
            session!,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil,
            outputHandler: { status, _, imageBuf, _, _ in
                decodeStatus = status
                if let imageBuf {
                    imageBuffer = imageBuf
                }
            }
        )
        guard status == noErr else { throw DecoderError.decode(status) }
        guard decodeStatus == noErr else { throw DecoderError.decode(decodeStatus) }
        guard let imageBuffer else { throw DecoderError.noImageBuffer }
        return imageBuffer
    }

    private func ensureSession(for system: DVSystem) throws {
        if currentSystem == system, session != nil { return }

        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        let codec: CMVideoCodecType = (system == .pal)
            ? kCMVideoCodecType_DVCPAL
            : kCMVideoCodecType_DVCNTSC

        var format: CMFormatDescription?
        let par: NSDictionary = [
            kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: 16,
            kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: 15
        ]
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_PixelAspectRatio: par
        ]
        let fdStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: system.width,
            height: system.height,
            extensions: extensions,
            formatDescriptionOut: &format
        )
        guard fdStatus == noErr, let format else {
            throw DecoderError.formatDescription
        }
        formatDescription = format

        let destAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: outputPixelFormat,
            kCVPixelBufferWidthKey: system.width,
            kCVPixelBufferHeightKey: system.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
        ]

        var newSession: VTDecompressionSession?
        let cbStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: destAttrs,
            decompressionSessionOut: &newSession
        )
        guard cbStatus == noErr, let newSession else {
            throw DecoderError.sessionCreate(cbStatus)
        }
        session = newSession
        currentSystem = system
    }
}

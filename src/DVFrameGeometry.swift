//
//  DVFrameGeometry.swift
//  DVLive
//
//  Геометрия кадра DV.
//
//  В DV пиксель неквадратный, а признак «широкий экран» лежит в VAUX Video Control
//  пакете кадра. 16:9WIDE на камкордерах Sony — анаморфная запись: картинка
//  физически сжата по ширине внутри кадра 720×576, и её надо растянуть обратно
//  (мануал DCR-PC115E, стр. 59: «the picture … is compressed in the widthwise
//  direction»). Syphon pixel aspect ratio не передаёт вообще, поэтому в Syphon
//  отдаём уже растянутый кадр с квадратным пикселем: тогда любой потребитель
//  (OBS, Zoom через OBS Virtual Camera, QuickTime) показывает правильную
//  пропорцию без ручных настроек.
//

import Accelerate
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

public enum DVAspect: Sendable, Equatable {
    /// 4:3 (обычный режим)
    case standard
    /// 16:9, анаморфно (16:9WIDE)
    case wide

    public var label: String {
        switch self {
        case .standard: return "4:3"
        case .wide: return "16:9 (анаморфно)"
        }
    }
}

public enum DVFrameGeometry {

    // MARK: - Определение режима

    /// Читает признак широкого экрана из VAUX Video Control пакета кадра.
    /// Правило то же, что в FFmpeg (`dv_extract_video_info`):
    /// `is16_9 = (vsc[2] & 7) == 2 || (!apt && (vsc[2] & 7) == 7)`.
    public static func detect(in frame: Data, system: DVSystem) -> DVAspect {
        frame.withUnsafeBytes { raw -> DVAspect in
            guard raw.count > 600 else { return .standard }
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let offset = videoControlOffset(bytes) else { return .standard }
            let apt = bytes[4] & 0x07
            let code = bytes[offset + 2] & 0x07
            let isWide = code == 0x02 || (apt == 0 && code == 0x07)
            return isWide ? .wide : .standard
        }
    }

    /// Пакет DV_VIDEO_CONTROL (0x61) чередуется между чётными и нечётными
    /// DIF-последовательностями, поэтому перебираем кандидатов как FFmpeg.
    private static func videoControlOffset(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        for c in 0..<10 {
            let offset = (c & 1) == 0
                ? (80 * 5 + 48 + 5 + c * 12_000)
                : (80 * 3 + 8 + c * 12_000)
            guard offset + 7 < bytes.count else { break }
            if bytes[offset] == 0x61 { return offset }
        }
        return nil
    }

    // MARK: - Пиксельный аспект

    /// PAR для пары (режим, система). PAL 4:3 — 16:15, PAL 16:9 — 64:45,
    /// NTSC 4:3 — 8:9, NTSC 16:9 — 32:27 (значения из профилей DV в FFmpeg).
    public static func pixelAspect(_ aspect: DVAspect, system: DVSystem) -> (horizontal: Int, vertical: Int) {
        switch (aspect, system) {
        case (.standard, .pal): return (16, 15)
        case (.wide, .pal): return (64, 45)
        case (.standard, .ntsc): return (8, 9)
        case (.wide, .ntsc): return (32, 27)
        }
    }

    /// Размер кадра в квадратных пикселях: 720×576 → 768×576 (4:3) или 1024×576 (16:9);
    /// 720×480 → 640×480 или 854×480.
    public static func displaySize(width: Int, height: Int,
                                   par: (horizontal: Int, vertical: Int)) -> (width: Int, height: Int) {
        guard par.vertical > 0 else { return (width, height) }
        let scaled = Int((Double(width) * Double(par.horizontal) / Double(par.vertical)).rounded())
        // Чётная ширина — требование большинства кодеков и шкалеров.
        let even = scaled % 2 == 0 ? scaled : scaled + 1
        return (even, height)
    }

    public static func displaySize(of buffer: CVPixelBuffer, aspect: DVAspect, system: DVSystem) -> (width: Int, height: Int) {
        displaySize(width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer),
                    par: pixelAspect(aspect, system: system))
    }

    public static func squarePixelSize(width: Int, height: Int,
                                       par: (horizontal: Int, vertical: Int)) -> (width: Int, height: Int)? {
        guard par.horizontal != par.vertical else { return nil }
        return displaySize(width: width, height: height, par: par)
    }

    // MARK: - Аттачменты кадра

    public static func setPixelAspect(of buffer: CVPixelBuffer,
                                      aspect: DVAspect,
                                      system: DVSystem) {
        let par = pixelAspect(aspect, system: system)
        setPixelAspect(of: buffer, par: par)
    }

    public static func setPixelAspect(of buffer: CVPixelBuffer,
                                      par: (horizontal: Int, vertical: Int)) {
        let value: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: par.horizontal,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: par.vertical,
        ]
        CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey,
                              value, .shouldPropagate)
    }

    public static func pixelAspect(of buffer: CVPixelBuffer) -> (horizontal: Int, vertical: Int)? {
        guard let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) as? NSDictionary,
              let horizontal = attachment[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int,
              let vertical = attachment[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int,
              horizontal > 0, vertical > 0 else { return nil }
        return (horizontal, vertical)
    }
}

// MARK: - Растяжка до квадратного пикселя

/// Масштабирует BGRA-кадр до квадратного пикселя через vImage.
/// Держит маленький пул буферов: Syphon читает IOSurface асинхронно, поэтому
/// переиспользовать один буфер нельзя.
public final class DVSquarePixelScaler {
    private let poolSize = 3
    private var pool: [CVPixelBuffer] = []
    private var poolWidth = 0
    private var poolHeight = 0
    private var index = 0

    public init() {}

    public func scale(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        guard let destination = dequeue(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else { return nil }

        var sourceBuffer = vImage_Buffer(
            data: sourceBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source))
        var destinationBuffer = vImage_Buffer(
            data: destinationBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destination))

        let error = vImageScale_ARGB8888(&sourceBuffer, &destinationBuffer, nil,
                                         vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else { return nil }

        // Пиксель теперь квадратный — говорим об этом и метаданными.
        DVFrameGeometry.setPixelAspect(of: destination, par: (1, 1))
        return destination
    }

    private func dequeue(width: Int, height: Int) -> CVPixelBuffer? {
        if poolWidth != width || poolHeight != height {
            pool.removeAll()
            poolWidth = width
            poolHeight = height
            index = 0
        }
        if pool.isEmpty {
            let attributes: NSDictionary = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            for _ in 0..<poolSize {
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attributes,
                                          &buffer) == kCVReturnSuccess,
                      let buffer else { return nil }
                pool.append(buffer)
            }
        }
        let buffer = pool[index % pool.count]
        index += 1
        return buffer
    }
}

// MARK: - Кадр для проверки глазами

public enum DVFrameDebug {

    /// Декодирует первый полный кадр файла, применяет геометрию (deinterlace →
    /// растяжка до квадратного пикселя) и пишет PNG. Нужен, чтобы проверить
    /// пропорции без камеры.
    @discardableResult
    public static func writeFrame(from path: String, to pngPath: String) -> Int32 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            fputs("[dv-frame-selftest] не читается \(path)\n", stderr)
            return 2
        }
        let frameBytes = 144_000
        guard data.count >= frameBytes else {
            fputs("[dv-frame-selftest] файл короче кадра PAL (144000)\n", stderr)
            return 2
        }
        let frameData = data.subdata(in: 0..<frameBytes)
        let aspect = DVFrameGeometry.detect(in: frameData, system: .pal)
        print("[dv-frame-selftest] режим кадра: \(aspect.label)")

        let decoder = DVDecoder()
        let assembled = DVAssembledFrame(data: frameData, system: .pal)
        do {
            let decoded = try decoder.decode(assembled)
            let progressive = DVDeinterlacer.bobBottomField(decoded) ?? decoded
            DVFrameGeometry.setPixelAspect(of: progressive, aspect: aspect, system: .pal)
            let target = DVFrameGeometry.displaySize(of: progressive, aspect: aspect, system: .pal)

            var output = progressive
            if let par = DVFrameGeometry.pixelAspect(of: progressive),
               let size = DVFrameGeometry.squarePixelSize(width: CVPixelBufferGetWidth(progressive),
                                                          height: CVPixelBufferGetHeight(progressive),
                                                          par: par) {
                let scaler = DVSquarePixelScaler()
                guard let scaled = scaler.scale(progressive, width: size.width, height: size.height) else {
                    fputs("[dv-frame-selftest] не удалось растянуть кадр\n", stderr)
                    return 3
                }
                output = scaled
            }

            print("[dv-frame-selftest] извлечено "
                  + "\(CVPixelBufferGetWidth(progressive))×\(CVPixelBufferGetHeight(progressive)) "
                  + "→ \(CVPixelBufferGetWidth(output))×\(CVPixelBufferGetHeight(output)) "
                  + "(ожидалось \(target.width)×\(target.height))")

            var image: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(output, options: nil, imageOut: &image)
            guard status == noErr, let image else {
                fputs("[dv-frame-selftest] VTCreateCGImageFromCVPixelBuffer: \(status)\n", stderr)
                return 3
            }
            let url = URL(fileURLWithPath: pngPath) as CFURL
            guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
                fputs("[dv-frame-selftest] не могу создать \(pngPath)\n", stderr)
                return 2
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                fputs("[dv-frame-selftest] не могу записать \(pngPath)\n", stderr)
                return 2
            }
            print("[dv-frame-selftest] PNG: \(pngPath)")
            return 0
        } catch {
            fputs("[dv-frame-selftest] декод не удался: \(error)\n", stderr)
            return 3
        }
    }
}

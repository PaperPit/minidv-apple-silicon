//
//  SyphonOutput.swift — публикация декодированных DV-кадров в Syphon.
//  Потребитель: OBS Studio → источник "Syphon Client" → Start Virtual Camera.
//

import Foundation
import Metal
import CoreVideo
import Syphon

/// Публикует CVPixelBuffer в Syphon. Вызывать с одного потока-производителя.
final class SyphonOutput {

    static let serverName = "Sony DCR-PC115E"

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let server: SyphonMetalServer

    /// Кэш текстур поверх IOSurface: пул VideoToolbox переиспользует буферы,
    /// поэтому почти всегда попадаем и не аллоцируем на каждом кадре.
    private var textureCache: [IOSurfaceID: MTLTexture] = [:]

    /// Анаморфный кадр растягиваем до квадратного пикселя: Syphon PAR не несёт.
    private let scaler = DVSquarePixelScaler()
    private var loggedGeometry = ""

    private(set) var framesPublished: UInt64 = 0
    private(set) var framesSkippedNoIOSurface: UInt64 = 0
    private(set) var framesSkippedNoTexture: UInt64 = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[Syphon] Metal-устройство недоступно"); return nil
        }
        guard let queue = device.makeCommandQueue() else {
            NSLog("[Syphon] Не удалось создать MTLCommandQueue"); return nil
        }
        let server = SyphonMetalServer(name: Self.serverName,
                                       device: device,
                                       options: nil)
        self.device = device
        self.queue = queue
        self.server = server
        NSLog("[Syphon] Сервер «\(Self.serverName)» запущен")
    }

    deinit { stop() }

    func stop() {
        server.stop()
        textureCache.removeAll()
        NSLog("[Syphon] Остановлен, опубликовано кадров: \(framesPublished)")
    }

    /// Есть ли подписчики — можно не декодировать, когда OBS закрыт.
    var hasClients: Bool { server.hasClients }

    /// Отдать один декодированный кадр. pixelBuffer обязан быть IOSurface-backed.
    func publish(_ source: CVPixelBuffer) {
        let pixelBuffer = squarePixelBuffer(source)
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else {
            framesSkippedNoIOSurface &+= 1
            if framesSkippedNoIOSurface == 1 {
                NSLog("[Syphon] CVPixelBuffer не IOSurface-backed — нужен kCVPixelBufferIOSurfacePropertiesKey в атрибутах декодера")
            }
            return
        }
        let surface = surfaceRef.takeUnretainedValue()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let texture = texture(for: surface, width: width, height: height) else {
            framesSkippedNoTexture &+= 1
            return
        }
        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        server.publishFrameTexture(texture,
                                   on: commandBuffer,
                                   imageRegion: NSRect(x: 0, y: 0,
                                                       width: CGFloat(width),
                                                       height: CGFloat(height)),
                                   flipped: true)
        commandBuffer.commit()
        framesPublished &+= 1
    }

    /// Возвращает кадр с квадратным пикселем (или исходный, если он уже такой).
    private func squarePixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let par = DVFrameGeometry.pixelAspect(of: source),
              let target = DVFrameGeometry.squarePixelSize(width: width, height: height, par: par),
              let scaled = scaler.scale(source, width: target.width, height: target.height) else {
            return source
        }
        let key = "\(width)×\(height) PAR \(par.horizontal):\(par.vertical) → \(target.width)×\(target.height)"
        if loggedGeometry != key {
            loggedGeometry = key
            NSLog("[Syphon] геометрия: \(key)")
        }
        return scaled
    }

    private func texture(for surface: IOSurfaceRef,
                         width: Int, height: Int) -> MTLTexture? {
        let id = IOSurfaceGetID(surface)
        if let cached = textureCache[id],
           cached.width == width, cached.height == height { return cached }

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: d,
                                               iosurface: surface, plane: 0) else {
            NSLog("[Syphon] makeTexture(iosurface:) вернул nil — проверьте pixelFormat")
            return nil
        }
        if textureCache.count > 64 { textureCache.removeAll() }
        textureCache[id] = texture
        return texture
    }
}

// Интеграция:
//  1. Декодер обязан отдавать IOSurface-backed BGRA. В атрибутах
//     VTDecompressionSession должны быть:
//       kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
//       kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
//       kCVPixelBufferMetalCompatibilityKey: true
//  2. В пайплайне: `private let syphon = SyphonOutput()` один раз,
//     и `syphon?.publish(pixelBuffer)` на каждый готовый кадр.
//  3. Проверка: OBS → «+» → Syphon Client → «Sony DCR-PC115E» → Start Virtual Camera.
//     В OBS 32.0.x источник Syphon Client отдаёт пустой кадр (issue #12684) —
//     если framesPublished растёт, а картинки нет, ставьте OBS 31.x.

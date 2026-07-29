//
//  SyphonOutput.swift
//  ASFW / DVLive
//
//  Публикация декодированных DV-кадров как Syphon-сервера.
//  Потребитель: OBS Studio → источник "Syphon Client" → Start Virtual Camera.
//
//  Зачем: Camera Extension от OBS уже подписан и нотаризован OBS Project,
//  поэтому системная камера появляется без Team ID, provisioning profile
//  и платного Developer Program. Syphon передаёт кадры через IOSurface —
//  без копирования, задержка порядка одного кадра.
//
//  ──────────────────────────────────────────────────────────────────────────
//  УСТАНОВКА SYPHON
//
//    git clone https://github.com/Syphon/Syphon-Framework.git
//    cd Syphon-Framework
//    xcodebuild -project Syphon.xcodeproj -scheme Syphon -configuration Release
//
//  Полученный Syphon.framework перетащить в проект ASFW:
//    Target ASFW → General → Frameworks, Libraries, and Embedded Content
//    → Embed & Sign
//
//  Syphon написан на Objective-C. Если модульная карта не подхватывается,
//  добавьте bridging header со строкой:
//    #import <Syphon/Syphon.h>
//  и уберите `import Syphon` ниже.
//  ──────────────────────────────────────────────────────────────────────────
//

import Foundation
import Metal
import CoreVideo
import Syphon

/// Публикует CVPixelBuffer в Syphon. Потокобезопасен для вызова с одного
/// потока-производителя (тот же, что дренирует кольцо и декодирует кадры).
final class SyphonOutput {

    // MARK: - Конфигурация

    /// Имя, под которым сервер виден в OBS в списке Syphon-источников.
    static let serverName = "Sony DCR-PC115E"

    // MARK: - Приватное состояние

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let server: SyphonMetalServer

    /// Кэш текстур: MTLTexture поверх IOSurface создаётся один раз на каждый
    /// уникальный IOSurface. VideoToolbox переиспользует буферы из пула,
    /// поэтому кэш почти всегда попадает и мы не аллоцируем на каждом кадре.
    private var textureCache: [IOSurfaceID: MTLTexture] = [:]

    /// Диагностика — полезно вывести в UI рядом со счётчиками захвата.
    private(set) var framesPublished: UInt64 = 0
    private(set) var framesSkippedNoIOSurface: UInt64 = 0
    private(set) var framesSkippedNoTexture: UInt64 = 0

    // MARK: - Жизненный цикл

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[Syphon] Metal-устройство недоступно")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            NSLog("[Syphon] Не удалось создать MTLCommandQueue")
            return nil
        }
        let server = SyphonMetalServer(name: Self.serverName,
                                       device: device,
                                       options: nil)

        self.device = device
        self.queue = queue
        self.server = server

        NSLog("[Syphon] Сервер «\(Self.serverName)» запущен")
    }

    deinit {
        stop()
    }

    /// Явная остановка. После неё сервер исчезает из списка в OBS.
    func stop() {
        server.stop()
        textureCache.removeAll()
        NSLog("[Syphon] Сервер остановлен (опубликовано кадров: \(framesPublished))")
    }

    /// Есть ли сейчас потребители. Если false — можно не тратить такты
    /// на декодирование, когда OBS закрыт.
    var hasClients: Bool { server.hasClients }

    // MARK: - Публикация кадра

    /// Отдать один декодированный кадр в Syphon.
    ///
    /// - Parameter pixelBuffer: кадр из VideoToolbox. **Обязан быть
    ///   IOSurface-backed** — см. примечание о параметрах декодера ниже.
    func publish(_ pixelBuffer: CVPixelBuffer) {
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else {
            // Самая частая причина: сессия декодера создана без
            // kCVPixelBufferIOSurfacePropertiesKey. См. комментарий в конце файла.
            framesSkippedNoIOSurface &+= 1
            if framesSkippedNoIOSurface == 1 {
                NSLog("[Syphon] CVPixelBuffer не IOSurface-backed — проверьте атрибуты декодера")
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

    // MARK: - Кэш текстур

    private func texture(for surface: IOSurfaceRef,
                         width: Int,
                         height: Int) -> MTLTexture? {
        let id = IOSurfaceGetID(surface)
        if let cached = textureCache[id],
           cached.width == width, cached.height == height {
            return cached
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,   // должен совпадать с форматом декодера
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared   // Apple Silicon: единая память

        guard let texture = device.makeTexture(descriptor: descriptor,
                                               iosurface: surface,
                                               plane: 0) else {
            NSLog("[Syphon] makeTexture(iosurface:) вернул nil — проверьте pixelFormat")
            return nil
        }

        // Пул VideoToolbox конечен, кэш не растёт бесконечно.
        // Страховка на случай нештатной ротации буферов.
        if textureCache.count > 64 { textureCache.removeAll() }
        textureCache[id] = texture
        return texture
    }
}

// ────────────────────────────────────────────────────────────────────────────
// ИНТЕГРАЦИЯ В СУЩЕСТВУЮЩИЙ ПАЙПЛАЙН
//
// 1. Декодер обязан отдавать IOSurface-backed BGRA. При создании
//    VTDecompressionSession передайте:
//
//      let attrs: [CFString: Any] = [
//          kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
//          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
//          kCVPixelBufferMetalCompatibilityKey: true,
//          kCVPixelBufferWidthKey: 720,
//          kCVPixelBufferHeightKey: 576,
//      ]
//
//    Без kCVPixelBufferIOSurfacePropertiesKey публикация будет молча
//    пропускать все кадры — счётчик framesSkippedNoIOSurface это покажет.
//
// 2. Два выхода одновременно. Чтобы потом не переписывать код при переходе
//    на собственный CMIO-sink, заведите протокол и подписывайте на него оба:
//
//      protocol DVFrameSink: AnyObject {
//          var wantsFrames: Bool { get }
//          func consume(_ pixelBuffer: CVPixelBuffer)
//      }
//
//      extension SyphonOutput: DVFrameSink {
//          var wantsFrames: Bool { hasClients }
//          func consume(_ pb: CVPixelBuffer) { publish(pb) }
//      }
//
//    А в пайплайне держите массив `[DVFrameSink]` и раздавайте кадр всем,
//    у кого wantsFrames == true. DVLiveCameraFeeder встанет туда же
//    без единой правки в остальном коде.
//
// 3. Деинтерлейс. Для видеозвонка bob по одному полю (576i → 288p → апскейл)
//    визуально хуже, чем bwdif, но дешевле и даёт честные 50 обновлений
//    в секунду. Если у вас уже есть bob — оставьте его, Syphon от этого
//    не зависит.
//
// 4. Проверка в OBS:
//      • OBS → Источники → «+» → Syphon Client
//      • в выпадающем списке выбрать «Sony DCR-PC115E»
//      • Start Virtual Camera
//
//    ВНИМАНИЕ: в OBS 32.0.x источник Syphon Client отдаёт пустой прозрачный
//    кадр (issue obsproject/obs-studio#12684). Если картинки нет, а
//    framesPublished растёт — проблема не в вашем коде, ставьте OBS 31.x.
//
// 5. Запуск OBS сразу с виртуальной камерой и без окна на виду:
//      open -a OBS --args --startvirtualcam
// ────────────────────────────────────────────────────────────────────────────

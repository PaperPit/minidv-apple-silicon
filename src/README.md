# Исходники живого пути

Копия модуля `DVLive/` из ASFireWire вместе с патчем — чтобы код можно было прочитать, не применяя
патч. Полный набор изменений (драйвер, камерное расширение, сборка, ресурсы) — в
[`../patches/asfw-minidv-live.patch`](../patches/asfw-minidv-live.patch).

Лицензия: Apache License 2.0 (производное от [ASFireWire](https://github.com/mrmidi/ASFireWire)),
см. [`../NOTICE`](../NOTICE).

| Файл | Роль |
|---|---|
| `DVDriverClient.swift` | userclient ASFWDriver: старт/стоп захвата, отображение кольца |
| `DVCaptureRing.swift` | потребитель кольца 480-байтных DIF-чанков (ABI с драйвером) |
| `DVFrameAssembler.swift` | сборка кадра точного размера (PAL 144 000 / NTSC 120 000) |
| `DVDecoder.swift` | VideoToolbox: кадр DV → CVPixelBuffer BGRA (IOSurface-backed) |
| `DVDeinterlacer.swift` | bob по нижнему полю → 50p |
| `DVFrameGeometry.swift` | 4:3 / 16:9WIDE, PAR, растяжка до квадратного пикселя (vImage) |
| `SyphonOutput.swift` | публикация кадра в Syphon-сервер «Sony DCR-PC115E» |
| `DVLivePipeline.swift` | всё вместе: дренаж кольца → декод → деинтерлейс → Syphon + звук |
| `DVSyphonRunner.swift` | запуск пайплайна по флагу `--syphon`, сторожевой таймер |
| `DVAudioExtractor.swift` | PCM из DIF-блоков (16 и 12 бит) + `DVAudioPlayer` |
| `DVAudioSupport.swift` | устройства CoreAudio, выбор приёмника, привязка графа |
| `DVAudioDiagnostics.swift`, `DVLiveDiagnostics.swift` | флаги проверок без камеры |

# ASFireWire patch — live MiniDV (video + audio)

Патч добавляет в [ASFireWire](https://github.com/mrmidi/ASFireWire) живой MiniDV: захват DV
с камкордера, звук прямо из DV-потока, правильную геометрию кадра, ярлык запуска «всё сразу»
и (как задел) камерное расширение Core Media I/O.

## Что внутри

| Часть | Файлы | Что делает |
|---|---|---|
| Живой захват | `DVLive/DVDriverClient.swift`, `DVCaptureRing.swift`, `DVFrameAssembler.swift` | клиент userclient, кольцо 480-байтных DIF-чанков, сборка кадра точного размера |
| Видео | `DVLive/DVDecoder.swift`, `DVDeinterlacer.swift`, `SyphonOutput.swift`, `DVLivePipeline.swift` | VideoToolbox → bob-деинтерлейс → Syphon |
| Геометрия | `DVLive/DVFrameGeometry.swift` | 4:3 и 16:9WIDE, растяжка до квадратного пикселя (vImage) |
| Звук | `DVLive/DVAudioExtractor.swift` (в нём же `DVAudioPlayer`), `DVAudioSupport.swift` | 16 бит/48 кГц и 12 бит/32 кГц → CoreAudio, приёмник по имени (BlackHole) |
| Диагностика | `DVLive/DVAudioDiagnostics.swift`, `DVLiveDiagnostics.swift` | флаги `--list-audio-devices`, `--audio-selftest`, `--dv-audio-selftest`, `--audio-render-selftest`, `--dv-frame-selftest` |
| Ярлык | `scripts/minidv-live/` | запуск камеры, звука, OBS и виртуальной камеры одним кликом |
| Приложение | `ASFW/ASFWApp.swift`, `ASFW/DVLiveCameraFeeder.swift`, `DriverInstallManager.swift`, вьюхи | флаги, установка расширений, фидер в камеру |
| Камерное расширение | `ASFWCamera/`, `ASFWCameraInstall/` | публикует «Sony DCR-PC115E» как системную камеру (см. ограничение ниже) |
| Драйвер | `ASFWDriver/Async/Tx/ResponseSender.cpp` | фикс скорости ответов (S100) — без него AV/C не работает с i.LINK-камкордерами |
| Сборка | `project.yml`, `sign.sh`, `ASFW.xcodeproj` | новые цели, ad-hoc подпись |

## Чего в патче нет

`Vendor/Syphon.framework` — сторонний бинарный фреймворк, в патч не входит. Соберите его
(например, из [Syphon/Syphon-Framework](https://github.com/Syphon/Syphon-Framework)) и положите
как `ASFireWire/Vendor/Syphon.framework` — иначе сборка не найдёт `import Syphon`.

## Как применить

Патч снят относительно коммита `9055449` и проверен на чистом клоне именно этого коммита.

```bash
git clone https://github.com/mrmidi/ASFireWire.git
cd ASFireWire
git checkout 9055449
git apply /path/to/asfw-minidv-live.patch

# положить Syphon.framework в Vendor/, затем:
./build.sh --config Release && ./sign.sh
```

Проверка применения (`git apply --check` и применение на чистом клоне) — в [verification.txt](verification.txt).

Установка драйвера, выключение SIP, одобрение расширения и порядок отката — в
[гайде](../docs/guide.ru.html), разделы 2 и 6.

## Требования

- macOS 26 (Tahoe) на Apple Silicon; проверено на MacBook Air M1.
- Xcode 26 и `xcodegen` (`brew install xcodegen`) — проект генерируется из `project.yml`.
- SIP выключен и `systemextensionsctl developer on`: сборка ad-hoc, иначе AMFI не запустит dext.
- Для живого звука — BlackHole 2ch (`brew install --cask blackhole-2ch`).
- Для ярлыка — `node` (идёт с Homebrew или системным пакетом).

## Ограничения патча

- **CMIO-камера не активируется**: `ASFWCamera` собирается и подписывается ad-hoc, но система
  отвечает `OSSystemExtensionError.validationFailed (9)`. Нужна нормальная подпись (Developer ID
  или Development с совпадающим Team ID и Mach-service). Живой режим поэтому идёт через
  Syphon → OBS → OBS Virtual Camera.
- `DVLive` рассчитан на PAL 625/50 (144 000 байт на кадр); NTSC не проверялся.
- Патч на более новых версиях upstream может потребовать ручного разрешения конфликтов.

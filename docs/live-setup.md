# Живой режим: настройка и диагностика

Здесь собрано всё, что нужно, чтобы поднять камеру и звук в реальном времени, и как это проверять
без камеры.

> **Куда положены файлы.** В этом репозитории исходники ярлыка лежат в `tools/minidv-live/`
> (внутри ASFireWire, после применения патча, они же появляются в `scripts/minidv-live/`).
> Первый раздел ниже описывает путь через CMIO-расширение (`ASFWCamera`) — он написан, но
> **не активируется** из-за ad-hoc подписи; оставлен как справка. Рабочий путь — Syphon → OBS.

ASFW embeds `ASFWCamera.systemextension`, which publishes **Sony DCR-PC115E**.

## Personal Team / SIP-off path

Everything is **ad-hoc** so Team IDs match (`none`).  
`CMIOExtensionMachServiceName` is the bare ID `net.mrmidi.ASFW.ASFWCamera` (no TeamID prefix).

```bash
killall ASFW 2>/dev/null
cd ~/Developer/ASFireWire
./build.sh --config Release
./sign.sh
rm -rf /Applications/ASFW.app
cp -R build/DerivedData/Build/Products/Release/ASFW.app /Applications/
/Applications/ASFW.app/Contents/MacOS/ASFW --install-camera
```

Approve in **System Settings → General → Login Items & Extensions → Camera Extensions**.

Then:

```bash
open -n /Applications/ASFW.app
open -a "Photo Booth"
# Choose Sony DCR-PC115E — keep ASFW running; camcorder in CAMERA
```

If activation fails with `validationFailed (9)`, CMIO is rejecting bare Mach service on this OS — the remaining fix is a **paid Apple Developer Program** team so the camera can be Development-signed with `989597PNQ7.…` Mach service and activated by a matching Development host.

## Architecture

ASFW (ad-hoc, DriverKit userclient) feeds decoded DV into the CMIO **sink**; ASFWCamera forwards sink → source for Photo Booth. Camera has no DriverKit entitlements.

## Живой звук

Звук берётся из тех же кадров, что и видео: `DVAudioExtractor` режет PCM прямо из
DIF-блоков (16 бит/48 кГц и 12 бит/32 кГц — обе ветки сверены с FFmpeg побитово),
`DVAudioPlayer` играет его в выбранное устройство CoreAudio.

Приёмник по умолчанию — **BlackHole 2ch**: тогда любое приложение (OBS, Zoom,
QuickTime) видит звук с камкордера как микрофон, а системный вывод остаётся
свободным. Если играть в системный выход, звук уйдёт в колонки и в приложения
не попадёт.

```bash
brew install --cask blackhole-2ch        # один раз, спросит пароль администратора
```

Флаги — общие для живого режима и проверок:

| Флаг | Смысл |
|---|---|
| `--audio-device <имя\|uid\|default>` | куда играть; по умолчанию `BlackHole 2ch`, `default` — системный выход |
| `--no-audio` | выключить звуковую ветку |
| `--list-audio-devices` | список устройств CoreAudio |
| `--audio-selftest [сек]` | тон 1 кГц (L) / 3 кГц (R) через боевой плеер |
| `--dv-audio-selftest <файл.dv> [--pcm-out <файл>]` | прогон файла в темпе 25 к/с через боевой путь |
| `--audio-render-selftest <файл.dv> --pcm-out <файл>` | тот же граф офлайн-рендером, для сверки с FFmpeg |

Проверки не требуют камеры и FireWire:

```bash
/Applications/ASFW.app/Contents/MacOS/ASFW --list-audio-devices
/Applications/ASFW.app/Contents/MacOS/ASFW --audio-selftest 3
/Applications/ASFW.app/Contents/MacOS/ASFW --dv-audio-selftest /tmp/test48.dv --pcm-out /tmp/out.pcm
```

Тестовый поток для последних двух команд:

```bash
ffmpeg -y -f lavfi -i "testsrc2=size=720x576:rate=25" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=10.5" \
  -f lavfi -i "sine=frequency=3000:sample_rate=48000:duration=10.5" \
  -filter_complex "[1:a][2:a]join=inputs=2:channel_layout=stereo[a]" \
  -map 0:v -map "[a]" -c:v dvvideo -pix_fmt yuv420p -r 25 -c:a pcm_s16le -ar 48000 -ac 2 -t 10 -f dv test48.dv
```

Живой режим:

```bash
open -n /Applications/ASFW.app --args --syphon
```

В OBS: источник `Syphon Client` → «Sony DCR-PC115E», микрофон → `BlackHole 2ch`.
В Zoom: камера — OBS Virtual Camera, микрофон — `BlackHole 2ch`.

Ограничения: 12-битный звук разбирается как первая стереопара (ST1), вторая (ST2)
не публикуется; синхронность звука и видео задаётся приходом кадров (DV сам
кадрово-синхронный), отдельного общего таймлайна пока нет.

## Геометрия кадра (4:3 и 16:9WIDE)

В DV пиксель неквадратный, а 16:9WIDE у Sony — анаморфная запись: картинка
физически сжата по ширине внутри кадра 720×576 (мануал DCR-PC115E, стр. 59:
«the picture … is compressed in the widthwise direction»). Показывать кадр надо так:

| Режим камеры | PAR | Размер в квадратных пикселях |
|---|---|---|
| 4:3 | 16:15 | 768×576 |
| 16:9WIDE | 64:45 | 1024×576 |

Признак широкого экрана читается из VAUX Video Control пакета (тег `0x61`) по тому
же правилу, что в FFmpeg, и вешается на кадр как `kCVImageBufferPixelAspectRatioKey`.
Syphon pixel aspect ratio не передаёт вовсе, поэтому в Syphon кадр уходит уже
растянутым до квадратного пикселя. В OBS настраивать ничего не нужно: 1024×576 —
ровно 16:9, и в канву 1920×1080 источник ложится без полей и без искажений.

Проверка без камеры — извлекает кадр, применяет геометрию и пишет PNG:

```bash
/Applications/ASFW.app/Contents/MacOS/ASFW --dv-frame-selftest /tmp/wide.dv --png /tmp/wide.png
```

Тестовые потоки (4:3 и анаморфный 16:9):

```bash
ffmpeg -y -f lavfi -i "testsrc2=size=720x576:rate=25" -c:v dvvideo -pix_fmt yuv420p -r 25 -t 2 -f dv four3.dv
ffmpeg -y -f lavfi -i "testsrc2=size=720x576:rate=25" -c:v dvvideo -pix_fmt yuv420p -r 25 -aspect 16:9 -t 2 -f dv wide.dv
```

Ограничение: CMIO-камера (Photo Booth/Zoom напрямую) по-прежнему объявляет поток
как 720×576 с PAR 16:15, поэтому в 16:9WIDE она покажет сжатый кадр. Путь CMIO
сейчас не активируется (ad-hoc подпись), а живой режим идёт через Syphon — там
геометрия правильная. При возврате к CMIO описание формата надо строить из
аттачмента кадра.

## Ярлык MiniDV Live

Один клик вместо трёх запусков. Ярлык живёт в `/Applications/MiniDV Live.app`,
исходники — в `scripts/minidv-live/` (обычный bash плюс помощник на node),
переустановка: `scripts/minidv-live/install.sh`.

Что делает при запуске:

1. проверяет, что драйвер ASFW загружен, а BlackHole установлен
   (если BlackHole нет — запускает только видео и пишет об этом в лог);
2. останавливает прошлый живой захват (`--syphon`) и поднимает новый:
   видео в Syphon, звук в BlackHole;
3. открывает OBS и через obs-websocket приводит текущую сцену к рабочему виду:
   добавляет источник `Sony DCR-PC115E` (тип `syphon-input`) и звуковой вход
   `BlackHole 2ch` (`coreaudio_input_capture`), вписывает видео в канву;
4. включает виртуальную камеру (`StartVirtualCam`) — без этого браузер видит
   `OBS Virtual Camera` в списке устройств, но картинки не получает.

Лог: `~/Library/Logs/MiniDVLive.log`.

Тонкости, которые уже учтены в ярлыке:

- obs-websocket должен быть включён (ярлык включает `server_enabled` в
  `~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`
  сам). Если OBS в этот момент был открыт — сервер подхватится после его перезапуска.
- Syphon-сервер в OBS выбирается по `uuid`, а когда uuid сменился (новый запуск ASFW)
  совпадение ищется по паре `name` + `app_name`. Ярлык прописывает все три поля
  на каждом запуске — иначе источник остаётся чёрным.
- `OBS Virtual Camera` — это расширение системы: оно перечисляется в списке камер
  всегда, даже когда OBS закрыт, и объявляет единственный формат 1920×1080@60.
  Кадры идут только при активном выходе виртуальной камеры, поэтому ярлык включает
  его сам (`MINIDV_NO_VIRTUALS=1` — не включать).
- Отладочный режим без окон: `MINIDV_NO_DIALOG=1 "/Applications/MiniDV Live.app/Contents/MacOS/MiniDVLive"`.

Глобальный микрофон OBS (`Микр/доп`, микрофон MacBook) ярлык не трогает: если он
включён, в запись попадёт и он. Мут — в микшере OBS.

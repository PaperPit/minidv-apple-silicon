# Правки в существующие файлы ASFireWire

Два файла нужно изменить вручную. Оба находятся в форке ASFireWire с уже
написанным live-пайплайном (`DVLive/`).

---

## 1. `DVLive/DVLivePipeline.swift`

Четыре вставки. Все — рядом с существующими строками, ничего не удаляется.

### 1.1 Поле

```diff
     private var running = false
+    private var syphon: SyphonOutput?
```

### 1.2 Создание сервера при старте

```diff
         ring = mapped
         running = true
+        syphon = SyphonOutput()
```

Сервер создаётся вместе с захватом, а не в `init()`, — чтобы он не висел
в системе, когда пайплайн не работает.

### 1.3 Остановка

```diff
             running = false
             handler = nil
+            syphon?.stop()
+            syphon = nil
```

### 1.4 Публикация кадра

```diff
             let progressive = DVDeinterlacer.bobBottomField(decoded) ?? decoded
+            syphon?.publish(progressive)
```

Публикация идёт прямо в `emit()`, сразу после деинтерлейса, на той же очереди
`pipeline` — без лишних переходов между потоками.

**Автоматическое применение:**

```bash
cd ~/Developer/ASFireWire
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path('DVLive/DVLivePipeline.swift'); s = p.read_text()
if 'syphon' in s: sys.exit('уже применено')
edits = [
 ("    private var running = false",
  "    private var running = false\n    private var syphon: SyphonOutput?"),
 ("        ring = mapped\n        running = true",
  "        ring = mapped\n        running = true\n        syphon = SyphonOutput()"),
 ("            running = false\n            handler = nil",
  "            running = false\n            handler = nil\n            syphon?.stop()\n            syphon = nil"),
 ("            let progressive = DVDeinterlacer.bobBottomField(decoded) ?? decoded",
  "            let progressive = DVDeinterlacer.bobBottomField(decoded) ?? decoded\n            syphon?.publish(progressive)"),
]
for a, b in edits:
    if a not in s: sys.exit(f'не найден якорь: {a[:50]}…')
    s = s.replace(a, b, 1)
p.write_text(s); print('DVLivePipeline.swift обновлён')
PY
```

---

## 2. `ASFW/ASFWApp.swift`

Запуск живого режима по флагу командной строки.

```diff
             DVLiveCameraFeeder.shared.startMonitoring()
+            if ProcessInfo.processInfo.arguments.contains("--syphon") {
+                DVSyphonRunner.shared.start()
+            }
```

**Почему по флагу, а не всегда.** Живой пайплайн занимает изохронный контекст
приёма в драйвере. Если бы он стартовал автоматически, вкладка захвата с ленты
перестала бы работать — они делят одно кольцо.

**Автоматическое применение:**

```bash
cd ~/Developer/ASFireWire
python3 - <<'PY'
import pathlib, sys, re
p = pathlib.Path('ASFW/ASFWApp.swift'); s = p.read_text()
if 'DVSyphonRunner' in s: sys.exit('уже применено')
m = re.search(r'^(\s*)DVLiveCameraFeeder\.shared\.startMonitoring\(\)\s*$', s, re.M)
if not m: sys.exit('не найден вызов startMonitoring()')
ind = m.group(1)
add = (f"\n{ind}if ProcessInfo.processInfo.arguments.contains(\"--syphon\") {{"
       f"\n{ind}    DVSyphonRunner.shared.start()"
       f"\n{ind}}}")
p.write_text(s[:m.end()] + add + s[m.end():])
print('ASFWApp.swift обновлён')
PY
```

---

## 3. `project.yml`

Подключение фреймворка. **Не через интерфейс Xcode** — проект генерируется
XcodeGen'ом, правки в UI будут стёрты.

```diff
     dependencies:
       - target: ASFWDriver
         embed: true
         codeSign: false
       - package: swift-sdk
         product: MCP
+      - framework: Vendor/Syphon.framework
+        embed: true
+        codeSign: true
```

Если после генерации компилятор не найдёт заголовки, добавьте в `settings.base`
того же target:

```yaml
        FRAMEWORK_SEARCH_PATHS:
          - "$(inherited)"
          - "$(SRCROOT)/Vendor"
```

---

## 4. Требование к декодеру

`SyphonOutput` строит `MTLTexture` поверх `IOSurface`, поэтому буферы обязаны
быть IOSurface-backed и в формате BGRA. В атрибутах `VTDecompressionSession`:

```swift
let attrs: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    kCVPixelBufferMetalCompatibilityKey: true,
    kCVPixelBufferWidthKey: 720,
    kCVPixelBufferHeightKey: 576,
]
```

Без `kCVPixelBufferIOSurfacePropertiesKey` публикация молча пропустит все кадры.
Счётчик `framesSkippedNoIOSurface` в `SyphonOutput` это покажет, и в лог уйдёт
предупреждение при первом же пропуске.

---

## 5. Развязка на будущее

Чтобы потом не переписывать пайплайн при переходе на собственное CMIO-расширение,
имеет смысл завести протокол приёмника и раздавать кадр всем подписчикам:

```swift
protocol DVFrameSink: AnyObject {
    var wantsFrames: Bool { get }
    func consume(_ pixelBuffer: CVPixelBuffer)
}

extension SyphonOutput: DVFrameSink {
    var wantsFrames: Bool { hasClients }
    func consume(_ pb: CVPixelBuffer) { publish(pb) }
}
```

Тогда `DVLiveCameraFeeder` встанет туда же без правок в остальном коде, и оба
выхода смогут работать параллельно.

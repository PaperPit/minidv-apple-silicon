> **Обновление 4 октября 2026.** Разбор ниже сделан в июле. Баг 1 (скорость ответов S100) исправлен —
> фикс входит в [`../patches/asfw-minidv-live.patch`](../patches/asfw-minidv-live.patch);
> актуальное состояние, включая живой режим, — в [гайде](guide.ru.html), раздел 3.

# Баги ASFireWire, найденные при работе с камкордером

Конфигурация: ASFireWire commit `9055449` (VERSION 0.2.0-audio), MacBook Air M1
(T8103), macOS 26.5.2 (25F84), Apple Thunderbolt→FireWire A1463 (LSI/Agere FW643,
PCI `11c1:5901`), Sony DCR-PC115E (GUID `0x0800460101DBB1F0`, vendor `0x080046`,
specID `0x00A02D`, узел S100).

Материал пригоден для issue в upstream — камкордер на этом драйвере до сих пор
никто не проверял, всё тестовое железо автора работает на S400.

---

## Баг 1 — жёстко зашитая скорость S400 в исходящих ответах

**Статус:** исправлен локальным патчем, в upstream не отправлен.

`ASFWDriver/Async/Tx/ResponseSender.cpp`, строки 34 и 42:

```cpp
constexpr uint8_t kSpeedS400 = 0x02;
...
uint32_t BuildQ0(uint8_t tLabel, uint8_t tCode) {
    return (static_cast<uint32_t>(kSrcBusID & 0x01) << 23) |
           (static_cast<uint32_t>(kSpeedS400 & 0x07) << 16) |   // ← всегда S400
           (static_cast<uint32_t>(tLabel & 0x3F) << 10) |
           ...
```

Исходящие async-**запросы** используют скорость из speed map — драйвер корректно
опускает узел до S100 после двух таймаутов:

```
[Discovery] Node 1: Timeout at S400 (count=1)
[Discovery] Node 1: Downgraded S400 → S200
[Discovery] Node 1: Timeout at S200 (count=1)
[Discovery] Node 1: Downgraded S200 → S100
[Discovery][speed_success] Node 1: Success at S100
```

А исходящие **ответы** — нет. Камкордер i.LINK работает только на S100 и
физически не принимает пакеты S400. Результат — шторм:

```
[Async] AT completion raw ack nibble 0x8 survived normalization:
        tLabel=34 event=0x03 (evt_missing_ack) ackCount=0
[Async] AT-resp DROPPED: tLabel=34 event=0x03 (evt_missing_ack)
[AVC] AVCUnit: UNIT_INFO failed: result=8
[AVC] AVCUnit: SUBUNIT_INFO failed: result=10
```

**Почему не всплывало раньше.** Всё тестовое железо автора — Apogee Duet,
Focusrite Saffire, PreSonus StudioLive, Midas Venice — устройства S400.

**Временное исправление:** отвечать всегда на S100. Ответы — мелкие пакеты,
потеря скорости на них не значима, а S100 принимают все устройства без
исключения. После патча строки `AT-resp DROPPED` исчезают полностью, Config ROM
читается чисто:

```
[Async] OnARResponse: completing tLabel=10 gen=8 node=0xFFC1 rcode=0x0 len=4
... (24 успешных транзакции подряд)
[Discovery] Device Discovered: GUID 0x0800460101DBB1F0, Node 1, TA 61883
```

**Правильное исправление для upstream:** отзеркаливать скорость принятого
запроса, как это делает Linux (`fw_fill_response`). Мешает баг 3.

---

## Баг 2 — AT-completion не сопоставляется для блочных записей

**Статус:** открыт.

После исправления бага 1 транзакции на проводе проходят **полностью**. Трасса из
встроенной диагностики (вкладка «1394 Diagnostics»):

```
Δt(us)     Dir Ctx    TL  TCode    Speed Src    Dst    Address        Ack   RCode
7051.3     TX  ATReq  34  WrBlock  S100  0xFFC0 0xFFC1 0xFFFFF0000B00 0x00  complete
9952.2     RX  ARReq  34  WrBlock  S?    0xFFC1 0xFFC0 0xFFFFF0000D00 0x12  0x0F
9964.9     TX  ATRsp  34  WrResp   S100  0xFFC0 0xFFC1 -              0x00  complete
```

Читается так: наша AV/C-команда уходит в `FCP_COMMAND`, камера через **2,9 мс**
отвечает записью в наш `FCP_RESPONSE`, наше железо шлёт `ack_pending` (`0x12`),
мы отправляем write-response. И так все 16 транзакций подряд, без единого сбоя.

Но драйвер этого не видит и через 750 мс помечает транзакцию как истёкшую:

```
[Async] ⏱️ OnTimeout: tLabel=34 state=ATPosted ackCode=0x0 retries=0
[Async] ❌ FAILED: tLabel=34 ATPosted - AT completion never arrived after 2 attempts
[Async] t34: ATPosted → TimedOut (OnTimeout)
[AVC] AVCUnit: UNIT_INFO failed: result=8
```

Квадлетные чтения (Config ROM) сопоставляются нормально — ломаются именно
**блочные записи с payload**.

**Подозреваемое место:** `ATContextBase::ExtractCompletionTLabel`, где индекс
дескриптора-заголовка вычисляется как `(headIndex + capacity - 2) % capacity`.
Для пакетов с payload геометрия дескрипторов другая.

**Практическое следствие:** AV/C-команды до камеры доходят и выполняются,
интерфейс просто рапортует «no FCP response». На захват DV-потока не влияет
вообще — изохронный приём идёт мимо AV/C.

---

## Баг 3 — скорость принятого пакета теряется при разборе

**Статус:** открыт. Блокирует правильное исправление бага 1.

В OHCI скорость приёма лежит в битах 21–23 трейлерного `xferStatus`
(Linux: `p.speed = (status >> 21) & 0x7`). В ASFireWire структура `ARPacketView`
(`ASFWDriver/Async/Rx/PacketRouter.hpp`) хранит:

```cpp
uint16_t xferStatus;   // Low 16 bits of xferStatus (includes event code)
```

Младшие 16 бит. Биты скорости отрезаются, отзеркалить скорость запроса в ответе
невозможно. В `PacketRouter.cpp:223` при этом стоит заглушка:

```cpp
event.speed = 0; // S100
```

**Исправление:** расширить поле до 32 бит либо добавить `uint8_t speed` в
`ARPacketView` и использовать его в `ResponseSender::BuildQ0`.

---

## Наблюдение — gap count 44 при оптимальном 5

```
Gap Count: 44                     Expected Gap: 5
Decision: SuppressedByRoleMode    Configured Role Mode: Client Only (no BM/IRM)
BM Node: none                     Remote Cycle Continuity: Yes (node 1)
```

Драйвер сознательно не претендует на роль Bus Manager, поэтому gap count никто
не оптимизирует. Для шины из двух узлов 44 — заметно раздутые арбитражные паузы.
На проверочном захвате не помешало (0 переполнений кольца за 76 секунд), но при
длинных лентах или более загруженной шине сюда стоит вернуться.

Цикл-мастером выступает камера — она root и CMC-capable.

---

## Успешный результат для отчёта

Изохронный приём, помеченный в проекте как экспериментальный, отработал
76 секунд подряд:

| Показатель | Значение |
|---|---|
| Кадров | 1895 |
| Потеряно | 1 (0,05 %) |
| Переполнений кольца | 0 |
| Isoch packets seen | 621 186 (8194/с — шина на своих 8000 Гц) |
| DV source packets | 568 554 (ровно 300 на кадр — норма PAL DV) |
| Non-DV packets | 0 |
| Байт записано | 272 880 000 (делится на 144 000 без остатка) |
| Таймкод ленты | сохранён (`00:04:22:08`) |

Живой режим (камера в CAMERA, канал 63) работает стабильно, кадры доезжают до
системной камеры через Syphon и виртуальную камеру OBS.

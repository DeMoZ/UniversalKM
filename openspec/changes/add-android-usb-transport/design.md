# Design

## Context

Зачем — proposal.md, раздел «Why». Требования — `specs/android-usb-link/spec.md`. Изменение строится поверх `add-ble-hid-input-bridge` («базовое изменение», ссылки «базовый D5») и не зависит от `add-chameleon-ble-link`.

Что есть сейчас (проверено в коде и на устройстве):

- **Один транспорт.** `AppDelegate` создаёт `ChameleonHIDTransport` и отдаёт его `AppStateManager` и `InputManager`. `InputManager` шлёт `moveMouse / scroll / setButtons / key / sendNeutral(to: peerID)`; адрес — `UInt16` peer ID хоста. Статус — `TransportStatus` (`notConnected / unsupportedFirmware / ready(ChameleonHIDState)`); `AppStateManager` берёт из него подписанные хосты и привязывает к ним устройства схемы (`PlacedDevice.hostPeerID`, `DeviceArrangement.bindHosts`, «Перепривязать», `unboundHosts`). Peer ID Chameleon — маленькие числа peer manager, `0xFFFF` = без bond.
- **Дескриптор и отчёты готовы.** `HIDReportDescriptor.reportMap` — составной: клавиатура (Report ID 1, 8 байт, LED‑выход) и мышь (Report ID 2, 7 байт: кнопки, X/Y int16, колесо, AC Pan). `KeyboardReport`/`MouseReport` кодируют байты, `MouseAccumulator` переносит дробные части.
- **AOA2 HID проверен 2026‑11‑09** (Samsung `04e8:6860`, пробник на libusb в scratchpad сессии): `GET_PROTOCOL` (51) → 2; `REGISTER_HID` (54, value = id, index = длина дескриптора), `SET_HID_REPORT_DESC` (56), `SEND_HID_EVENT` (57), `UNREGISTER_HID` (55) — vendor‑запросы по нулевой конечной точке, без перевода устройства в режим accessory, без отладки по USB, без диалога на телефоне. Мышь и клавиатура с отдельными дескрипторами без Report ID работали.
- **libusb без root работал,** хотя README утверждает обратное для адаптера AIC: там нужен был захват интерфейса (SCSI), а здесь — только управляющие запросы к устройству, для которых захват не нужен.
- **Встроенный Bluetooth Mac не может быть HID‑периферией** (`CBPeripheralManager` отказывает для `0x1812`, проверено 2026‑11‑08) — поэтому без кабеля Android управляется только через Chameleon.

## Goals / Non-Goals

**Goals:**
- Android по USB работает как полноценный хост схемы: те же сценарии, что у хоста Chameleon (пересечение края, возврат, «Перепривязать», удаление).
- `InputManager` и логика схемы не знают, каким способом подключено устройство: они по‑прежнему шлют по peer ID.
- Без новых сторонних зависимостей, если IOKit пропускает AOA‑запросы (D2).

**Non-Goals:**
- Автоматическое переключение одного и того же телефона между USB и Chameleon, когда выдёргивают кабель (один телефон — одна привязка; см. Open Questions).
- Беспроводное управление Android без Chameleon (ADB по Wi‑Fi, uhid) — требует режима разработчика, отдельное изменение при желании.
- Режим accessory AOA (аудио, свой протокол с приложением на телефоне) — только HID.
- iOS/iPadOS по USB — не поддерживают HID от USB‑хоста.

## Decisions

### D1. Отдельный транспорт и маршрутизатор, а не расширение `ChameleonHIDTransport`

- `AndroidUSBTransport: HIDTransport` — свой последовательный `DispatchQueue`, свой список USB‑хостов.
- `CompositeHIDTransport: HIDTransport` — держит оба транспорта и отправляет вызов по диапазону peer ID (D3). `start / setEnabled / shutdown` — обоим; `sendNeutral(to:)` — владельцу peer ID.
- Статус: `TransportStatus` остаётся статусом Chameleon; Android‑транспорт отдаёт свой `AndroidUSBStatus` (список устройств: id, имя, серийный номер, состояние `detected / registered / unsupported(причина)`). `AppStateManager` объединяет подключённые хосты обоих: `subscribedPeers = chameleonSubscribed + androidRegistered`.

*Альтернатива:* одна общая модель «хост» с перечислением способов подключения внутри `TransportStatus`. Отвергнута: ломает уже работающий Chameleon‑код и тесты ради косметики; объединение в `AppStateManager` — десяток строк.

### D2. USB через IOKit (`IOUSBDeviceInterface.DeviceRequest`), libusb — запасной путь

AOA нужны только vendor‑запросы на нулевую конечную точку. Legacy‑интерфейс IOKit (`IOUSBDeviceInterface` через `IOCreatePlugInInterfaceForService`) позволяет `DeviceRequestTO` без `USBDeviceOpen`, если устройство открыто другим драйвером — так же поступает libusb на macOS (при отказе в эксклюзивном открытии продолжает с управляющими запросами), и именно этот путь сработал в пробнике. Поиск и отключение — `IOServiceAddMatchingNotification` на `IOUSBHostDevice`, как `ChameleonDeviceWatcher` для последовательных портов.

Задача 1.1 подтверждает это на том же Samsung. Если IOKit без открытия отказывает, берём libusb 1.0.27 как системную библиотеку (`systemLibrary` в SwiftPM + встраивание `libusb-1.0.dylib` в бандл в `build-app.sh`) — проверено, работает; решение записывается сюда.

*Альтернатива:* новый `IOUSBHost` framework. Отвергнута: `IOUSBHostDevice` без `.deviceCapture` (нужен закрытый entitlement) не даёт управляющих запросов к устройству, которое держит системный составной драйвер.

### D3. Peer ID для USB‑хостов: диапазон `0x8000…0x80FE`, связь с серийным номером

`PlacedDevice.hostPeerID` уже `UInt16` и сохраняется в схеме. USB‑хост получает ID из диапазона `0x8000…0x80FE`, выдаваемый один раз на пару (vendor ID, серийный номер USB) и хранимый в UserDefaults (`androidUSBPeers`: `[ключ: ID]`). Так устройство после перезапуска и после смены режима USB (другой product ID) остаётся на своём месте в схеме. Chameleon peer ID — малые числа peer manager и `0xFFFF`; пересечений нет. Выдача и разбор ключа — в Core (`AOAHID.swift`), с unit‑тестами.

Устройство без серийного номера (бывает у дешёвых) получает ключ по location ID порта и предупреждение в журнале: на другом порту оно будет новым.

*Альтернатива:* сменить `hostPeerID` на перечисление `.chameleon(UInt16) / .usb(String)`. Отвергнута: миграция сохранённых схем и правки `DeviceArrangement` и тестов без выигрыша для пользователя.

### D4. Кого опрашивать и когда регистрировать

- **Опрос `GET_PROTOCOL`** — только у устройств, похожих на Android: есть интерфейс ADB (`FF/42/01`), MTP/PTP (`06/01/01` или vendor‑интерфейс со строкой «MTP»), RNDIS/модем Android, либо PID AOA Google (`18d1:2d00…2d05`). Исключаются Apple (`05ac`), Chameleon (`6868:8686`) и устройства с HID/Mass Storage без перечисленных интерфейсов. Ответ ≥ 2 → `detected`, иначе `unsupported`.
- **Регистрация** — только для устройства, чей peer ID привязан в схеме (или когда ожидающее устройство схемы привязывается к нему, как к новому хосту Chameleon), и пока передача включена (`setEnabled(true)`). Иначе устройство остаётся в `unboundHosts` как предложение «Добавить» (требование «Подключение только с согласия пользователя»).
- **Регистрируется одно HID‑устройство** (AOA id 1) с составным `HIDReportDescriptor.reportMap`; события — байты отчёта с Report ID в начале (`[1] + keyboard`, `[2] + mouse`). Если Android не примет составной дескриптор с Report ID (задача 1.2), регистрируем два HID (id 1 — клавиатура, id 2 — мышь) с дескрипторами без Report ID, как в пробнике.
- **Снятие** — `sendNeutral`, затем `UNREGISTER_HID`, при удалении из схемы, «Перепривязать», `setEnabled(false)` и `shutdown(timeout:)` (синхронно, общий бюджет 0,3 с как у Chameleon).

### D5. Доставка и слияние

Как у Chameleon (базовый D5): клавиатура и кнопки — очередь без потерь; движение мыши и прокрутка копятся в `MouseAccumulator` и уходят одним отчётом, когда предыдущий запрос завершён. Один управляющий запрос на full/high speed занимает ~1 мс, поэтому частота отчётов мыши не ограничена радиоканалом; потолок — 250 Гц, чтобы не забивать шину. Ошибка запроса `kIOReturnNoDevice / NotResponding` = устройство пропало → `detected` снимается, хост отключён.

### D6. Отключение кабеля

`kIOTerminatedNotification` для устройства → хост пропадает из `subscribedPeers` → `AppStateManager`/`InputManager` уже обрабатывают пропажу хоста, у которого ввод: возврат на Mac (базовое поведение для Chameleon). Отправлять на телефон уже нечего. Повторное появление (тот же vendor + серийный) → регистрация заново, без участия пользователя.

### D7. Документация: Android по проводу — первым

README.md и README.ru.md (одинаковая структура):
1. Шапка: «телефон или планшет» → сначала Android по кабелю, без дополнительных устройств; бейдж AOA рядом с бейджем Chameleon.
2. «How it works» — два способа, таблица: **Android по USB** (кабель, ничего не покупать, только Android, задержка ~1 мс) и **ChameleonUltra / nRF52840 / ESP32** (без провода, Android + iPhone + iPad, до трёх устройств). Схема `docs/images/architecture.svg` показывает оба пути.
3. Раздел «Android по проводу»: что нужно (кабель с данными, Android с AOA 2 — большинство с Android 4.1+), как добавить, ограничения (не работает у устройств с урезанным AOA; без провода — только через Chameleon).
4. Затем существующие разделы про Chameleon («Why not the Mac's built-in Bluetooth», «What does work», прошивка, сопряжение, USB/Bluetooth к Chameleon) — блоком «Без провода: ChameleonUltra и похожие платы». Фраза «claiming a USB device… libusb is refused even as root» уточняется: отказ касается захвата интерфейса.
5. Таблица Features: строка «🔌 USB or Bluetooth» → «🔌 Android по кабелю или Bluetooth через Chameleon».

## Risks / Trade-offs

- [Производитель урезал AOA (некоторые Xiaomi/Huawei, Android Go)] → устройство помечается `unsupported` с причиной в журнале и в панели; README перечисляет проверенные модели; путь через Chameleon остаётся.
- [В режиме «Только зарядка» устройство может не показывать MTP/ADB, и D4 его не опросит] → задача 1.3 проверяет на Samsung; если интерфейсов нет, добавляем список vendor ID производителей Android как второй признак.
- [Регистрация клавиатуры прячет экранную клавиатуру на телефоне, пока приложение работает] → то же, что у Chameleon; регистрация только для устройств схемы, снятие при выходе и выключении передачи.
- [Приложение «упало» и не сняло регистрацию] → Android сам снимает HID при отключении кабеля; при следующем запуске приложение сначала шлёт `UNREGISTER_HID` для своих id, потом регистрирует.
- [Другая программа (scrcpy `--otg`, Android File Transfer) работает с тем же устройством] → AOA‑HID id разных программ не конфликтуют, но ввод будет от обеих; в журнал — предупреждение, если `REGISTER_HID` вернул ошибку.
- [IOKit не пропустит запросы без открытия (D2)] → libusb как запасной путь, уже проверен.
- [Раскладка: Android переводит коды клавиш по своей раскладке физической клавиатуры] → как у Chameleon; README ссылается на настройку «Физическая клавиатура» в Android.

## Migration Plan

Сохранённые схемы не меняются: устройства Chameleon держат свои peer ID. Новые USB‑хосты получают ID из `0x8000…`. Откат — удалить USB‑устройства из схемы или вернуть предыдущую версию: старые версии не видят хостов `0x8000…` и показывают такие устройства как ожидающие.

## Open Questions

- Нужен ли позже **автоматический переход одного телефона с USB на Chameleon**, когда выдёргивают кабель (телефон сопряжён с Chameleon и подключён кабелем; одно место в схеме, два хоста). Это отдельное изменение: оно расширяет привязку устройства до списка хостов и не меняет того, что делается здесь.

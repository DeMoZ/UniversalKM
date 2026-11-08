# Design

## Context

Зачем — proposal.md, раздел «Why». Требования — `specs/android-usb-link/spec.md` и `specs/android-wifi-link/spec.md`. Изменение строится поверх `add-ble-hid-input-bridge` («базовое изменение», ссылки «базовый D5») и не зависит от `add-chameleon-ble-link`.

Что есть сейчас (проверено в коде и на устройстве):

- **Один транспорт.** `AppDelegate` создаёт `ChameleonHIDTransport` и отдаёт его `AppStateManager`, `InputManager` и `BLEDemo`. `InputManager` шлёт `moveMouse / scroll / setButtons / key / sendNeutral(to: peerID)`; адрес — `UInt16` peer ID хоста. Статус — `TransportStatus` (`notConnected / unsupportedFirmware / ready(ChameleonHIDState)`); `AppStateManager` берёт из него подписанные хосты и привязывает к ним устройства схемы (`PlacedDevice.hostPeerID`, `DeviceArrangement.bindHosts`, «Перепривязать», `unboundHosts`). Peer ID Chameleon — маленькие числа peer manager, `0xFFFF` = без bond.
- **Дескриптор и отчёты готовы.** `HIDReportDescriptor.reportMap` — составной: клавиатура (Report ID 1, 8 байт, LED‑выход) и мышь (Report ID 2, 7 байт: кнопки, X/Y int16, колесо, AC Pan). `KeyboardReport`/`MouseReport` кодируют байты, `MouseAccumulator` переносит дробные части.
- **USB: AOA2 HID проверен 2026‑11‑09** (Samsung S10e `04e8:6860`, пробник на libusb): `GET_PROTOCOL` (51) → 2; `REGISTER_HID` (54, value = id, index = длина дескриптора), `SET_HID_REPORT_DESC` (56), `SEND_HID_EVENT` (57), `UNREGISTER_HID` (55) — vendor‑запросы по нулевой конечной точке, без режима accessory, без отладки, без диалога на телефоне. libusb без root работал: нужны только управляющие запросы к устройству, без захвата интерфейса.
- **Wi‑Fi: ADB + `/system/bin/hid` проверен 2026‑11‑09** (тот же телефон, Android 12, кабель отключён): `adb shell hid -` читает поток JSON‑объектов (`{"id":1,"command":"register","name":…,"vid":…,"pid":…,"bus":"bluetooth","descriptor":[…]}`, затем `{"id":1,"command":"report","report":[…]}`) и создаёт UHID‑устройство; составной дескриптор с Report ID принят; пользователь `shell` в группе `uhid`. 360 отчётов мыши за 3,5 с прошли, текст набрался. Время ADB‑shell туда‑обратно по Wi‑Fi: медиана 8 мс, p90 12 мс, редкие выбросы ~100 мс. `ro.serialno` = серийный номер USB (`R28M303RHET`). `adb tcpip 5555` + `adb connect <ip>:5555` работают; адрес — из `ip -4 addr show wlan0`.
- **Встроенный Bluetooth Mac не может быть HID‑периферией** (`CBPeripheralManager` отказывает для `0x1812`, проверено 2026‑11‑08).

## Goals / Non-Goals

**Goals:**
- Android по USB и по Wi‑Fi — полноценный хост схемы: те же сценарии, что у хоста Chameleon.
- `InputManager` и логика схемы не знают канала: они по‑прежнему шлют по peer ID.
- Переход одного телефона между USB и Wi‑Fi без потери места в схеме и без возврата курсора.

**Non-Goals:**
- Своя реализация протокола ADB (TLS, SPAKE2) в приложении — используем `adb` пользователя (решение пользователя 2026‑11‑09); можно сделать отдельным изменением.
- Встраивание `adb` в бандл (лицензия SDK, размер, обновления).
- Переход одного телефона между Android‑каналами и Chameleon.
- Режим accessory AOA (аудио, свой протокол) — только HID.

## Decisions

### D1. Один Android‑транспорт с двумя каналами, Chameleon отдельно, маршрутизатор сверху

- `AndroidHIDTransport: HIDTransport` — свой последовательный `DispatchQueue`; хранит Android‑хосты по peer ID; у хоста до двух каналов: `AOALink` (USB) и `ADBLink` (Wi‑Fi/ADB). Активный канал — USB, если зарегистрирован, иначе ADB. Протокол канала: `register()`, `send(event: [UInt8])`, `unregister()`, `onLost`.
- `CompositeHIDTransport: HIDTransport` — маршрутизирует по диапазону peer ID (D3): `0x8000…0x80FE` — Android, остальное — Chameleon. `start / setEnabled / shutdown` — обоим.
- Статус: `TransportStatus` остаётся статусом Chameleon. Android‑транспорт отдаёт `AndroidStatus`: `adbPath?`, список устройств (peer ID, имя, серийный номер, каналы с состояниями `available / registered / unsupported(причина)`, активный канал). `AppStateManager` объединяет хосты: `subscribedPeers = chameleonSubscribed + androidRegistered`.

*Альтернатива:* два независимых Android‑транспорта (USB и ADB) в маршрутизаторе. Отвергнута: один телефон должен иметь один peer ID и переходить между каналами (спека «Один телефон по USB и по Wi‑Fi») — это решает владелец обоих каналов.

### D2. USB через IOKit (`IOUSBDeviceInterface.DeviceRequestTO`), libusb — запасной путь

AOA нужны только vendor‑запросы на нулевую конечную точку. Legacy‑интерфейс IOKit (`IOCreatePlugInInterfaceForService` → `IOUSBDeviceInterface`) позволяет `DeviceRequestTO` без `USBDeviceOpen`, когда устройство держит системный составной драйвер — так libusb работает на macOS, и этот путь сработал в пробнике. Поиск — `IOServiceAddMatchingNotification` на `IOUSBHostDevice` (первое появление и `kIOTerminatedNotification`).

Если IOKit без открытия отказывает (задача 1.1) — libusb 1.0.27 как `systemLibrary` + dylib в бандле; решение записывается сюда.

*Альтернатива:* фреймворк `IOUSBHost`. Отвергнута: `IOUSBHostDevice` без `.deviceCapture` (закрытый entitlement) не даёт запросов к устройству, которое держит системный драйвер.

### D3. Peer ID Android: `0x8000…0x80FE` по серийному номеру

`PlacedDevice.hostPeerID` — `UInt16`, сохраняется в схеме. Android‑хост получает ID из `0x8000…0x80FE`, выдаваемый один раз на серийный номер (USB `iSerialNumber` = `ro.serialno` по ADB) и хранимый в UserDefaults (`androidPeers`: `[серийный: ID]`). Поэтому телефон после перезапуска, смены режима USB (другой PID) и смены канала остаётся на месте. Peer ID Chameleon — малые числа и `0xFFFF`; пересечений нет. Реестр — в Core (`AndroidPeerRegistry`), с unit‑тестами.

Устройство без серийного номера по USB — ключ `usb-loc:<locationID>` (предупреждение в журнале: на другом порту оно станет новым, с ADB не объединится).

*Альтернатива:* `hostPeerID` → перечисление `.chameleon(UInt16) / .android(String)`. Отвергнута: миграция схем и тестов без выигрыша для пользователя.

### D4. USB: кого опрашивать, как регистрировать

- **Опрос `GET_PROTOCOL`** — только у устройств, похожих на Android: интерфейс ADB (`FF/42/01`), MTP/PTP (`06/01/01` или vendor‑интерфейс со строкой «MTP»), RNDIS/модем, либо PID AOA Google (`18d1:2d00…2d05`). Исключаются Apple (`05ac`), Chameleon (`6868:8686`). Ответ ≥ 2 → `available`, иначе `unsupported`.
- **Регистрация** — только для peer ID, привязанного в схеме, и пока передача включена. Одно HID (AOA id 1) с составным `reportMap`; события — `[reportID] + байты отчёта`. Если Android не примет составной дескриптор (задача 1.2) — два HID (id 1 клавиатура, id 2 мышь) без Report ID.
- **Снятие** — нейтральные отчёты, затем `UNREGISTER_HID`; при запуске сначала `UNREGISTER_HID` (остаток прошлого запуска).

### D5. Wi‑Fi: `adb` пользователя и `hid -` на телефоне

- **Поиск `adb`:** `$PATH` приложения, `/opt/homebrew/bin`, `/usr/local/bin`, `~/Library/Android/sdk/platform-tools`, `$ANDROID_HOME/platform-tools`. Версия ≥ 30 (есть `pair` и `mdns`). Приложение использует общий сервер adb (`adb start-server`) — так же, как Android Studio; не убивает его.
- **Список устройств:** `adb track-devices` (долгоживущий процесс, сообщает об изменениях) или опрос `adb devices -l` раз в 2 с, если `track-devices` недоступен. Для нового устройства — `adb -s <serial> shell getprop ro.serialno` → ключ D3. Устройства `unauthorized`/`offline` — в статусе с подсказкой.
- **Канал `ADBLink`:** процесс `adb -s <transport> shell hid -`, в stdin — строки JSON (`HidCommand` в Core): `register` с `reportMap`, `vid 0x1209`, `pid 0x0001`, `name "UniversalKM"`, `bus "bluetooth"` (без `bus` для Android < 12 — повтор без поля, если `hid` завершился с ошибкой разбора); `report` — `[reportID] + байты`. Снятие — нейтральные отчёты, закрыть stdin (`hid` удаляет устройство при выходе). Выход процесса = канал потерян.
- **ADB по USB тоже канал.** Если у телефона на кабеле включена отладка, он виден и в `adb devices` по USB. Активным всё равно будет AOA (D1); ADB‑канал по USB не регистрируется, пока зарегистрирован AOA — иначе на телефоне две клавиатуры.
- **«Отладка по Wi‑Fi» (Android 11+):** панель — поля «IP:порт» и «код» → `adb pair <ip:port> <code>`. Подключение — `adb mdns services` (сервис `_adb-tls-connect._tcp`, имя содержит серийный) → `adb connect <ip:port>`, повтор раз в 5 с для известных серийных, пока не подключён. Сам сервер adb тоже подключается к сопряжённым устройствам по mDNS — приложение не мешает этому.
- **`adb tcpip`:** кнопка «Включить Wi‑Fi» у телефона, видимого по ADB через USB: `ip -4 addr show wlan0` → IP, `adb -s <serial> tcpip 5555`, `adb connect <ip>:5555`; IP запоминается (`androidWifiAddress[серийный]`) и `adb connect` повторяется раз в 5 с, пока устройство в схеме и не подключено.
- **Обнаружение потери:** выход процесса `hid` или исчезновение транспорта из `adb devices` → канал потерян (спека «Потеря Wi‑Fi»: ≤ 3 с; TCP‑разрыв adb замечает через keepalive — проверить в задаче 5.3, при необходимости — свой пинг `shell` раз в 1 с).

### D6. Доставка и слияние

Как у Chameleon (базовый D5): клавиатура и кнопки — очередь без потерь; движение и прокрутка копятся в `MouseAccumulator` и уходят одним отчётом, когда канал готов. USB: один запрос ~1 мс, потолок мыши 250 Гц. ADB: запись строки в pipe не блокирует; потолок мыши 125 Гц, чтобы не копить очередь в TCP при выбросах задержки (слияние на стороне Mac, а не очередь в сети).

### D7. Переход между каналами

Когда активный канал теряется, а другой канал хоста `available`: регистрация на другом канале, отчёты продолжаются; хост не пропадает из `subscribedPeers` (ввод остаётся на телефоне). Перед переходом — нейтральный отчёт по новому каналу. Когда появляется USB при активном ADB: регистрация AOA, затем снятие ADB‑устройства — коротко может быть две клавиатуры, но отчёты идут только в одну.

### D8. Документация: Android — первым

README.md и README.ru.md (одинаковая структура):
1. Шапка и Features: «Android по кабелю или по Wi‑Fi, без дополнительных устройств; iPhone и iPad — через ChameleonUltra».
2. «How it works» — три способа, таблица: **USB** (кабель, ничего не включать, ~1 мс), **Wi‑Fi (ADB)** (режим разработчика и `adb`, ~5 мс), **ChameleonUltra / nRF52840 / ESP32** (Android + iPhone + iPad, без отладки, 15–30 мс). `docs/images/architecture.svg` — три пути.
3. Разделы «Android по проводу» и «Android по Wi‑Fi» (установка `brew install android-platform-tools`, «Отладка по Wi‑Fi» и сопряжение по коду, `adb tcpip`, ограничения).
4. Затем существующие разделы про Chameleon блоком «iPhone, iPad и без отладки: ChameleonUltra и похожие платы». Фраза про libusb уточняется.

## Risks / Trade-offs

- [Производитель урезал AOA] → `unsupported` с причиной; остаются Wi‑Fi и Chameleon.
- [В режиме «Только зарядка» нет MTP/ADB, D4 не опросит] → задача 1.3; запасной признак — список vendor ID производителей Android.
- [`hid` отсутствует или shell без группы `uhid` на каком‑то Android] → канал `unsupported("hid")` с причиной из stderr; README перечисляет проверенные модели.
- [Сервер adb перезапускает другая программа (Android Studio, scrcpy)] → процессы `hid` умрут → канал потерян → переподключение по D5; устройство остаётся в схеме.
- [Выбросы задержки Wi‑Fi ~100 мс] → слияние мыши (D6); клавиатура без потерь, но с задержкой; README честно пишет, что кабель быстрее.
- [Режим разработчика на телефоне — это риск безопасности] → README: «Отладку по Wi‑Fi» включать только в доверенной сети; Android сам выключает её при смене сети.
- [Две клавиатуры при переходе USB ↔ ADB (D7)] → отчёты идут в одну; снятие второй в течение ~100 мс.
- [macOS спросит «Локальная сеть» при mDNS] → mDNS делает сервер adb, а не приложение; проверить в 5.2, при запросе — ключ `NSLocalNetworkUsageDescription`.
- [IOKit не пропустит запросы без открытия (D2)] → libusb, уже проверен.

## Migration Plan

Схемы не меняются: устройства Chameleon держат свои peer ID; новые Android‑хосты — `0x8000…`. Откат — старые версии показывают Android‑устройства как ожидающие.

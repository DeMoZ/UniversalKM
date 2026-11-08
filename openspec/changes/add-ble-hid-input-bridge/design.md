# Design

## Context

Зачем это нужно — см. proposal.md, раздел «Why». Требования — в `specs/`. В репозитории уже есть каркас пакета, скрипты сборки `.app`, кодирование HID‑отчётов и накопитель движения в Core (задачи 1.1–1.2 и задел 1.4–1.5).

Окружение разработки: macOS 27, Xcode 27.1, Swift 6.4, Apple Silicon. Генераторов Xcode‑проектов (xcodegen, tuist) нет.

Ограничения платформы, которые определяют решения ниже:

- **Mac не может быть BLE HID периферией (проверено 2026‑11‑08, macOS 27):** `CBPeripheralManager.add` отклоняет сервисы 0x1812, 0x180A и 0x180F с ошибкой «The specified UUID is not allowed for this operation». Внешние USB‑Bluetooth‑адаптеры macOS не использует. Адаптер AIC8800 из ящика пользователя не переключить в рабочий режим: libusb даже под root не может отцепить драйвер Mass Storage без ограниченного права `com.apple.vm.device-access`. Поэтому роль BLE HID отдана внешнему устройству.
- **ChameleonUltra** (hw_v1, прошивка v2.1, USB `6868:8686`, CDC‑serial `/dev/cu.usbmodem…`) — nRF52840 с открытой прошивкой RfidResearchGroup/ChameleonUltra (GPL‑3.0): nRF5 SDK 17 и SoftDevice S140 7.2.0 лежат в репозитории; уже есть BLE‑периферия (Nordic UART Service, Battery, Peer Manager с bonding и опциональным статическим PIN), USB‑CDC с протоколом кадров `netdata` (SOF `0x11`, LRC, команда/статус/длина u16; на зафиксированном коммите заняты ID до 5013 и 6000–6005, 6010 — ISO14443‑4), DFU по USB со штатным загрузчиком. Ключ подписи DFU (`resource/dfu_key/chameleon.pem`) публичен в репозитории, значит, свои пакеты загрузчик примет. Пока Chameleon питается от USB, таймер сна остановлен.
- **Event tap, который блокирует события** (`.defaultTap`), требует разрешения Accessibility. Только чтение событий (`.listenOnly`) требует Input Monitoring. В App Sandbox фильтрующий tap не работает.
- **TCC‑разрешения** привязаны к подписи кода. Если каждая сборка подписана ad‑hoc, macOS считает её новым приложением и сбрасывает разрешения.
- **iOS** показывает курсор BLE‑мыши только при включённом AssistiveTouch (на iPadOS курсор поддерживается сразу). Android 9+ поддерживает HOGP мышь + клавиатуру без настроек.

## Goals / Non-Goals

**Goals:**
- Первым делом добиться, чтобы ChameleonUltra с режимом HID сопрягался с Android и iPhone и принимал отчёты с Mac, и только потом строить остальное.
- Режим HID — дополнение к штатной прошивке Chameleon, а не замена: NFC/RFID‑функции и штатный клиент продолжают работать, откат — официальный DFU‑пакет.
- Вынести всю логику, не зависящую от железа (дескрипторы, кодирование отчётов, раскладка клавиш, детектор края, конечный автомат), в библиотеку с unit‑тестами.
- Ввод Mac ни при каких обстоятельствах не должен «застрять» в захвате: горячая клавиша, автоматический возврат, возврат при выходе и при отключении tap.
- Сборка и запуск из командной строки, без ручной настройки Xcode‑проекта.

**Non-Goals:**
- Несколько устройств на схеме и одновременно подключённых хостов, переключение между ними. Модель расположения — список, чтобы добавить это позже без миграции.
- Тип устройства «Компьютер» (Windows/Linux по BLE HID технически работает так же) — позже, тип в модели расширяемый.
- Автоматическое определение ориентации экрана устройства. BLE HID — односторонний канал: хост не сообщает периферии ни ориентацию, ни размер экрана, а приложения на устройстве нет. Ориентация переключается кнопкой (D14). Изменение ориентации проходит через одну точку — `AppStateManager.setOrientation(_:source:)` с `source: .manual`. Если позже появится приложение на устройстве (оно сможет сообщать ориентацию, например, через отдельную GATT‑характеристику), оно будет вызывать ту же функцию с `source: .device`.
- Возврат на Mac выводом курсора с устройства обратно через край: Mac не знает позицию курсора на хосте, потому что хост сам ускоряет указатель. Возврат — только горячей клавишей и в автоматических случаях.
- Абсолютное позиционирование, жесты трекпада (pinch, swipe), мультимедийные клавиши (Consumer Control), буфер обмена, перетаскивание файлов.
- Сопутствующее приложение на телефоне, App Store, App Sandbox, автообновление, запуск при входе в систему.
- Отдельное окно настроек: всё живёт в панели строки меню. Шаг прокрутки пока задан константой. Скорость указателя настраивается для каждого устройства (D10).

## Decisions

### D1. Swift Package + скрипт сборки `.app` вместо `.xcodeproj`
`Package.swift` с тремя таргетами:
- `UniversalKMCore` (library) — чистая логика без ввода‑вывода и без event tap: `HIDReportDescriptor`, `HIDReports` (кодирование), `ChameleonFrame` (кодек кадров `netdata` и команды режима HID, D5), `KeyCodeMap` (virtual keycode macOS → HID Usage), `DeviceArrangement` + `ArrangementLayout` (модель, прилипание, зона передачи), `HandoffZoneDetector`, `Hotkey` (модель, проверка допустимости, сопоставление), `CaptureStateMachine`, `MouseAccumulator`.
- `UniversalKM` (executable) — `UniversalKMApp.swift`, `HIDTransport.swift` (протокол), `ChameleonHIDTransport.swift`, `SerialPort.swift`, `ChameleonDeviceWatcher.swift`, `InputManager.swift`, `PermissionsManager.swift`, `DisplayLayoutProvider.swift`, `AppStateManager.swift`, `MenuBarView.swift`, `ArrangementView.swift`, `HotkeyRecorderView.swift`.
- `UniversalKMCoreTests` — тесты на Swift Testing.

Спайк на CoreBluetooth (`BluetoothHIDServer.swift`) и ObjC‑хелпер для перехвата исключений (`ObjCSupport`) удаляются: они больше не нужны.

`scripts/build-app.sh` запускает `swift build -c release`, собирает `build/UniversalKM.app` (`Contents/MacOS/UniversalKM`, `Contents/Info.plist` из `Resources/Info.plist`) и подписывает: `codesign --force --options runtime --entitlements Resources/UniversalKM.entitlements --sign "$SIGN_IDENTITY"`. По умолчанию берётся первая идентичность «Apple Development» из связки ключей. Если её нет — ad‑hoc подпись и явное предупреждение, что разрешения будут сбрасываться при каждой пересборке. `scripts/run.sh` собирает и запускает `open build/UniversalKM.app`.

*Почему не xcodeproj:* генераторов нет, а `project.pbxproj`, написанный вручную, хрупкий и плохо читается в ревью. `Package.swift` открывается в Xcode как есть, тесты запускаются через `swift test`.
*Альтернатива:* Xcode‑проект через «File → New». Его можно создать позже поверх тех же исходников, если понадобится нотаризация или архив через Xcode.

### D2. Ключи Info.plist и entitlements
`Resources/Info.plist`:

| Ключ | Значение | Зачем |
|---|---|---|
| `CFBundleIdentifier` | `com.universalkm.UniversalKM` | стабильный ID для TCC |
| `CFBundleName` / `CFBundleExecutable` | `UniversalKM` | |
| `CFBundlePackageType` | `APPL` | |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` / `1` | |
| `LSMinimumSystemVersion` | `14.0` | |
| `LSUIElement` | `true` | нет значка в Dock, только строка меню |

Для Accessibility и Input Monitoring ключей в Info.plist нет — они выдаются в System Settings. Приложение само Bluetooth не использует, поэтому `NSBluetoothAlwaysUsageDescription` не нужен (ключ, добавленный в задаче 1.2, удаляется).
`Resources/UniversalKM.entitlements`: без App Sandbox, hardened runtime. Доступ к USB‑serial (`/dev/cu.*`) вне песочницы entitlements не требует.

### D3. GATT‑структура HOGP — в прошивке Chameleon
HID‑сервис строится модулем `ble_hids` из nRF5 SDK 17 (в апстриме его нет в сборке — добавляется в Makefile и `sdk_config.h`):
- **HID 0x1812**: HID Information `[0x11,0x01, 0x00, 0x02]` (bcdHID 1.11, country 0, NormallyConnectable), Report Map (D4), HID Control Point, Protocol Mode (Report), Report keyboard input (ID 1), Report keyboard output (ID 1, светодиоды — принимаются и игнорируются), Report mouse input (ID 2). Дескрипторы Report Reference и CCCD `ble_hids` создаёт сам. Protocol Mode `ble_hids` создаёт только вместе с boot‑характеристиками клавиатуры, поэтому они включены (`is_kb = true`, boot‑мыши нет). Хосты используют Report Protocol; в Boot Protocol работает только клавиатура (отчёт в boot‑характеристику), мышь отбрасывается.
- **Device Information 0x180A** (`ble_dis`): Manufacturer «RfidResearchGroup», PnP ID (USB‑IF, VID/PID режима HID — константы, Open Questions).
- **Battery 0x180F**: уже есть в апстриме, с реальным уровнем заряда.
- Nordic UART Service апстрима остаётся — штатное мобильное приложение Chameleon продолжает работать, когда режим HID выключен.

Безопасность: характеристики HID — `SEC_JUST_WORKS` (шифрование), а при включённом статическом PIN Chameleon (`ble_pairing_enable`) — `SEC_MITM`, как штатные сервисы; bonding — через Peer Manager апстрима. Апстрим при выключенном PIN отвергает сопряжение, а с PIN использует MITM с вводом ключа (у Chameleon нет экрана для случайного ключа). Поэтому патч `ble_main.c`: в режиме HID сопряжение не отвергается, и если PIN выключен, на `PM_EVT_CONN_SEC_PARAMS_REQ` уходят параметры Just Works (LESC, bonding, без MITM). С PIN телефон спросит его — штатное поведение.
Реклама в режиме HID: флаги, список UUID16 `0x1812, 0x180F`, Appearance `BLE_APPEARANCE_HID_KEYBOARD` (0x03C1), имя — в scan response (`ble_advertising_hid_mode_set` в `ble_main.c`, данные меняются на ходу). Сервисы HID и DIS есть в таблице GATT всегда (менять её на ходу нельзя), но реклама HID и отчёты — только в режиме HID. Режим выключен после каждого сброса. Имя устройства остаётся `ChameleonUltra`, чтобы не сломать поиск штатного клиента.
Одно BLE‑соединение (`NRF_SDH_BLE_PERIPHERAL_LINK_COUNT 1`, как в апстриме): пока телефон подключён как клавиатура, штатное мобильное приложение Chameleon подключиться не может.

*Почему составное устройство с Report ID, а не два периферийных устройства:* у Chameleon одно соединение, а хосты одинаково поддерживают составные HID‑устройства.

### D4. Report Map и формат отчётов
- **Клавиатура, Report ID 1, input, 8 байт:** `[modifiers, reserved, k1..k6]`. Usage Page 0x07, модификаторы 0xE0–0xE7 (биты), коды 0x00–0x65.
- **Клавиатура, Report ID 1, output, 1 байт:** 5 бит светодиодов + 3 бита паддинга. Принимается и игнорируется.
- **Мышь, Report ID 2, input, 7 байт:** `[buttons(5 бит + 3 паддинг), x int16 LE, y int16 LE, wheel int8, pan int8]`. X/Y — Logical −32767..32767, Relative. Wheel — Generic Desktop 0x38. Pan — Consumer 0x0238 (AC Pan).

16‑битные X/Y вместо классических 8‑битных: быстрое движение мыши на Mac легко превышает ±127 за событие, а дробить его на несколько отчётов значит тратить слоты BLE. Android и iOS 16‑битные относительные поля поддерживают.
Единственный источник байтов Report Map — `firmware/src/ukm_report_map.h` (C‑массив). Swift‑константа `HIDReportDescriptor.reportMap` должна совпадать с ним: unit‑тест читает заголовок, разбирает байты и сравнивает (так прошивка и приложение не разойдутся). Корректность проверяется на телефоне в шаге 1.

### D5. Канал Mac → Chameleon: кадры `netdata` по USB‑CDC, слияние мыши, очередь клавиатуры
**Транспорт.** `HIDTransport` — протокол (`sendMouse`, `sendKey`, `sendNeutral`, `setEnabled`, поток статусов), его реализует `ChameleonHIDTransport`. Модули 2–3 работают только с протоколом.
- `ChameleonDeviceWatcher`: `IOServiceAddMatchingNotification` на `IOUSBHostDevice` с `idVendor 0x6868 / idProduct 0x8686` (появление и исчезновение), путь порта — `kIOCalloutDeviceKey` дочернего `IOSerialBSDClient`.
- `SerialPort`: `open(O_RDWR | O_NOCTTY | O_NONBLOCK)`, termios raw 115200 8N1 (для USB‑CDC скорость условна), `DispatchSourceRead` на очереди `ukm.serial`; всё состояние транспорта живёт на этой очереди.
- Кодек кадров (`ChameleonFrame` в Core): SOF `0x11`, LRC1, cmd u16 BE, status u16 BE, len u16 BE, LRC2, data, LRC3 — как `netdata.h` апстрима; потоковый парсер с ресинхронизацией по SOF.

**Команды режима HID** (диапазон 9000+, версия протокола 1; 6000–6005 заняты апстримом после v2.3.0). Статусы: OK = `0x68` (`STATUS_SUCCESS`), BUSY = `0xA0`, NOT_CONNECTED = `0xA1`, неверные данные = `0x60`. Каждый ответ на 9001–9003 несёт байт `state`:

| ID | Команда | Данные запроса | Ответ |
|---|---|---|---|
| 9000 | `UKM_HID_GET_INFO` | — | `[protocolVersion u8, state u8, peerId u16 BE]` |
| 9001 | `UKM_HID_SET_ENABLED` | `[0/1]` | `[state]`; 0 — пустые отчёты, разорвать соединение и остановить рекламу до следующего сброса (иначе сопряжённый телефон сам переподключится к «клавиатуре», и iOS спрячет экранную клавиатуру) |
| 9002 | `UKM_HID_KEYBOARD` | 8 байт отчёта | статус OK / BUSY / NOT_CONNECTED, `[state]` |
| 9003 | `UKM_HID_MOUSE` | 7 байт отчёта | статус OK / BUSY / NOT_CONNECTED, `[state]` |
| 9004 | `UKM_HID_STATE` (запрос) | — | `[state u8, peerId u16 BE, peerAddr 6 байт]`; state: 0 выключен, 1 реклама, 2 подключён, 3 подключён и подписан на отчёты |

Официальная прошивка на 9000 отвечает «неизвестная команда» (`0x67`) → статус «неподходящая прошивка» (spec «Проверка прошивки»).

**Поток.**
- Движение мыши и прокрутка суммируются в `MouseAccumulator` в `Double`. В отчёт идёт целая часть, дробный остаток остаётся до следующего отчёта (D10). Кнопки — текущий bitmask. Изменение кнопки выделяет накопленное движение в отдельный отчёт до отчёта с новыми кнопками.
- **В полёте не больше одного кадра вообще.** Приёмник `dataframe.c` апстрима держит один кадр: пока он ждёт обработки в главном цикле, новые байты отбрасываются, как и всё, что пришло в том же USB‑пакете после конца кадра. Следующий кадр уходит только после ответа на предыдущий (ответ — 1–2 мс по USB). Пока ответ не пришёл, движение копится в `MouseAccumulator`. Отчёты клавиатуры **не** сливаются: FIFO с приоритетом над мышью.
- Прошивка кладёт отчёт в очередь уведомлений SoftDevice (`ble_hids_inp_rep_send`); `NRF_ERROR_RESOURCES` → ответ BUSY, Mac повторяет через 2 мс (мышь — уже со слитым движением). Очередь HVN остаётся по умолчанию: её увеличение меняет требования SoftDevice к RAM, а слияние мыши и так не даёт очереди копиться.
- Если USB‑порт закрылся или пропало питание USB, прошивка сама шлёт телефону нейтральные отчёты (spec «Chameleon вынут с зажатыми клавишами»); если очередь занята — повторяет на `BLE_GATTS_EVT_HVN_TX_COMPLETE`.
- Режим HID просит connection interval 7,5–30 мс (`ble_conn_params_change_conn_params`): Android даёт 7,5 мс, iOS — 15 мс. Диапазон широкий, потому что `ble_conn_params` апстрима разрывает соединение, если хост держит интервал вне его.

### D6. Как определяется подключение и имя хоста
Состояние подключения знает прошивка: `BLE_GAP_EVT_CONNECTED/DISCONNECTED` и включение уведомлений на input‑отчётах (`BLE_HIDS_EVT_NOTIF_ENABLED`). Событий без запроса прошивка не шлёт: передатчик USB у апстрима один, и кадр, отправленный во время чужой передачи, получает `NRF_ERROR_BUSY` → `APP_ERROR_CHECK` → сброс. Поэтому Mac узнаёт состояние из байта `state` в каждом ответе на отчёт, а в простое опрашивает `UKM_HID_STATE` раз в 250 мс; при открытии порта — `UKM_HID_GET_INFO`. Подписку на отчёты прошивка определяет по значению CCCD, а не по событию записи: у сопряжённого телефона при переподключении CCCD восстанавливаются без записи. «Подключено» для приложения — state 3. После отключения прошивка снова рекламирует себя как HID‑устройство.
Идентификатор хоста — `peerId` Peer Manager (стабилен для сопряжённого телефона, в отличие от случайного BLE‑адреса).
Имя: BLE HID не даёт имя центрального устройства. Решение: имя задаёт пользователь, когда добавляет устройство на схему (D14). Так как на схеме одно устройство, любой подключённый хост считается им, и статус — «Подключено к <имя>». `peerId` последнего хоста запоминается в модели устройства — пригодится, когда устройств станет несколько. Если устройство ещё не добавлено, показывается «Подключено к устройству #<peerId>».

### D7. Event tap на отдельном потоке и синхронное решение о захвате
- `CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, …)` с маской: mouseMoved, left/right/otherMouseDown/Up/Dragged, scrollWheel, keyDown, keyUp, flagsChanged. Tap работает на выделенном `Thread` со своим `CFRunLoop`, чтобы не зависеть от загрузки main thread и не попадать под `tapDisabledByTimeout`.
- Колбэк должен вернуть результат (пропустить событие или `nil`) **синхронно**. Поэтому режим (`local`/`remote`) и флаг «хост подключён» хранятся в маленьком потокобезопасном состоянии (`OSAllocatedUnfairLock`), которое колбэк читает без хопов. Переходы, которые запускает tap (край, горячая клавиша), выполняются прямо в колбэке, а затем уведомляют `AppStateManager` через `MainActor`. Переходы, которые запускает приложение (отключение, меню, выход), вызывают потокобезопасный `InputManager.release()`.
- В колбэке нет тяжёлой работы: события переводятся в лёгкие значения и отправляются в `HIDTransport` (очередь `ukm.serial`, `async`).
- `tapDisabledByTimeout`/`tapDisabledByUserInput` → `CGEvent.tapEnable(tap:enable:true)` и, если режим `remote`, сначала release.

### D8. Расположение устройства и зона передачи
**Модель** (`DeviceArrangement`, Codable): `devices: [PlacedDevice]` (в этой версии не больше одного). `PlacedDevice` хранит `id`, `name`, `kind` (`phone`/`tablet`), `orientation` (`portrait`/`landscape`), `anchorDisplayUUID` (`CGDisplayCreateUUIDFromDisplayID`, переживает переподключение, в отличие от `CGDirectDisplayID`), `side` (`left`/`right`/`top`/`bottom`), `offset` — смещение начала устройства вдоль края в долях длины края (0…1), чтобы положение не зависело от разрешения, `pointerSpeed` (0.25…4.0, по умолчанию 1.0) и `lastHostIdentifier`.
**Размер** в глобальных точках: длинная сторона = 1/3 (телефон) или 1/2 (планшет) высоты главного дисплея, пропорции 9:19.5 (телефон) и 3:4 (планшет). В альбомной ориентации стороны меняются местами.
**Раскладка** (`ArrangementLayout`, чистые функции): из списка дисплеев `[(uuid, CGRect)]` в глобальных координатах CG (начало — верхний левый угол главного дисплея, y вниз) и модели считает прямоугольник устройства и зону.
- *Прилипание:* для отпущенного прямоугольника перебираются все внешние края всех дисплеев. Выбирается край с минимальным расстоянием, прямоугольник прижимается к нему вплотную, сдвиг вдоль края ограничивается так, чтобы он не перекрывал никакой дисплей. Затем сохраняются `side` и `offset`.
- *Зона:* отрезок пересечения стороны устройства с краем якорного дисплея минус части края, к которым вплотную примыкает другой дисплей (там курсор и так уходит на соседний дисплей).
- *Нет якорного дисплея:* используется расположение по умолчанию (справа от самого правого дисплея, по центру), модель не перезаписывается, а в состояние уходит флаг `isTemporary`.

**Детектор** (`HandoffZoneDetector`): точка (x, y) на дисплее D попадает в зону, если она лежит на последнем пикселе стороны `side` (`x ≥ maxX−1` / `x ≤ minX` / `y ≤ minY` / `y ≥ maxY−1`), проекция точки — внутри отрезка зоны, а дельта события направлена наружу (`dx>0` / `dx<0` / `dy<0` / `dy>0`). Условие по дельте не даёт курсору, просто оставленному у края, вызвать захват. Зона пересчитывается на main при смене модели или дисплеев (`CGDisplayRegisterReconfigurationCallback`) и под lock передаётся в состояние, которое читает колбэк tap (D7).

### D9. Фиксация и скрытие курсора
При захвате: запомнить точку, `CGWarpMouseCursorPosition` на 2 точки внутрь дисплея от края зоны (по стороне `side`), `CGAssociateMouseAndMouseCursorPosition(0)` (курсор стоит на месте, а `mouseEventDeltaX/Y` продолжают приходить), `CGDisplayHideCursor(kCGNullDirectDisplay)`. При возврате — обратные вызовы и `CGDisplayShowCursor`. Hide и show должны быть парными, поэтому в автомате стоит счётчик: hide не повторяется, если курсор уже скрыт.
Известная проблема: агент строки меню (`LSUIElement`), который не активен, может не суметь скрыть курсор. План проверки — в шаге 2: (а) публичный API как есть; (б) если не работает — `NSApp.activate()` при захвате и возврат фокуса прежнему приложению (`NSRunningApplication.activate`) при возврате; (в) приватный `CGSSetConnectionProperty("SetsCursorInBackground")` — только с явного согласия пользователя.
Курсор в любом случае «заперт» через `CGAssociate…(0)` и блокировку событий, так что функционально захват работает и с видимым курсором.

### D10. Пересылка событий
- Движение: `event.getDoubleValueField(.mouseEventDeltaX/Y)` × `pointerSpeed` устройства → `MouseAccumulator` (дробная часть переносится, D5).
  *Ускорение.* Дельты в событиях на `cghidEventTap` уже прошли через кривую ускорения и скорость указателя macOS. Это та же кривая, по которой двигается курсор Mac, и с `CGAssociateMouseAndMouseCursorPosition(0)` дельты продолжают приходить в этой же форме. Значит, если ускорение включено, на устройство уходит ускоренное движение, а если выключено — линейное, ровно как ощущается на Mac, без отдельного чтения настройки. Читать её (`com.apple.mouse.linear`, `com.apple.mouse.scaling`, `com.apple.trackpad.scaling`) нужно только для показа в панели и для лога.
  *Альтернатива — сырые отсчёты сенсора через `IOHIDManager` и своя кривая:* отклонена. Пришлось бы повторять закрытую кривую Apple для мышей и трекпадов, и при расхождении ощущение отличалось бы от Mac. Кроме того, понадобился бы отдельный захват устройств, хотя tap уже даёт нужные данные.
  *Целые поля `mouseEventDeltaX/Y` не используются:* они обрезают дробь, и при медленном движении курсор на устройстве «залипает».
- Кнопки: left = bit0, right = bit1, other по `mouseEventButtonNumber` (2 → middle bit2, 3/4 → back/forward bit3/bit4). Dragged — это движение при зажатой кнопке.
- Прокрутка: `scrollWheelEventPointDeltaAxis1/2` суммируется. Каждые N пикселей (константа, около 10 для трекпада) дают 1 «щелчок». У колеса с `scrollWheelEventIsContinuous == 0` берётся `DeltaAxis1` напрямую. Знак — как видит пользователь на Mac (с учётом natural scrolling).
- Клавиши: `keyboardEventKeycode` → `KeyCodeMap` → HID Usage. События с `keyboardEventAutorepeat == 1` поглощаются и не отправляются (автоповтор делает хост). `flagsChanged` → пересчёт битов модификаторов по keycode (0x37/0x36 L/R Cmd, 0x3A/0x3D Opt, 0x3B/0x3E Ctrl, 0x38/0x3C Shift, 0x39 CapsLock — как обычная клавиша 0x39). Набор нажатых клавиш — до 6, седьмая игнорируется.
- Fn и клавиши без отображения поглощаются.

### D11. Конечный автомат и горячая клавиша
`CaptureStateMachine` (Core) — чистая функция `(state, event) → (state, [effect])`.
Состояния: `local`, `remote(hostID)`.
События: `zoneHit`, `hotkey`, `hostDisconnected`, `permissionLost`, `tapDisabled`, `deviceRemoved`, `quit`, `releaseRequested`.
Эффекты: `hideCursor`, `showCursor`, `lockCursor`, `unlockCursor`, `sendNeutralReports`, `notifyUI`.

Горячая клавиша (`Hotkey`, Codable): `keyCode` (virtual keycode macOS) + `modifiers` (набор из control/option/command/shift). По умолчанию — Esc (53) + control+option+command. Допустима, если `keyCode` — не модификатор и среди модификаторов есть хотя бы один из control/option/command. Сопоставление: `keyDown` с тем же `keyCode` и **точно** тем же набором модификаторов (по маскам `CGEventFlags`, без учёта CapsLock/Fn). Распознаётся только в `remote`. Событие и последующий `keyUp` этой клавиши поглощаются. В `local` сочетание проходит в macOS. Текущая горячая клавиша лежит в том же lock‑состоянии, что и режим (D7), поэтому колбэк читает её без хопов. Хранится в `UserDefaults` (JSON).

*Почему без системной регистрации (`RegisterEventHotKey`, KeyboardShortcuts):* в remote всё равно всё идёт через наш tap и блокируется; в local сочетание не нужно перехватывать.

### D12. Разрешения
`PermissionsManager`:
- Accessibility: `AXIsProcessTrusted()`; запрос — `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
- Input Monitoring: `CGPreflightListenEventAccess()`; запрос — `CGRequestListenEventAccess()`.
- Кнопки «Открыть настройки» — `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` / `?Privacy_ListenEvent`.
- Уведомлений о выдаче разрешения нет, поэтому пока чего‑то не хватает, раз в 2 с идёт опрос. Как только всё выдано, создаётся event tap и опрос останавливается. Если `tapCreate` вернул `nil`, значит разрешения нет: показываем это в меню.

### D13. Связка в приложении (Swift 6 concurrency)
- `AppStateManager`: `@MainActor @Observable`. Владеет `HIDTransport` (`ChameleonHIDTransport`), `InputManager`, `PermissionsManager`, `DisplayLayoutProvider`. Публикует `transportStatus`, `mode`, `permissions`, `displays`, `arrangement`, `isArrangementTemporary`, `hotkey`, `hostDisplayName`. Хранит `arrangement` и `hotkey` в `UserDefaults` (JSON) и при каждом изменении передаёт в `InputManager` пересчитанную зону и горячую клавишу.
- `ChameleonHIDTransport` и `InputManager` — `final class … : @unchecked Sendable` с явной изоляцией (своя очередь / lock). Причина — колбэки C‑API (IOKit, event tap, `DispatchSource`) с произвольных потоков. Наружу — `AsyncStream`/колбэки, которые `AppStateManager` читает на `MainActor`.
- Запуск — AppKit (`main.swift`: `NSApplication`, `.accessory`, `AppDelegate`), а не SwiftUI `App`: сцена‑заглушка `Settings` показывает пустое окно при активации агентского приложения (проверено).
- Значок и панель — `NSStatusItem` + `NSPopover` (`.transient`, без анимации) с `NSHostingController` (`sizingOptions = .preferredContentSize`, панель меняет высоту по содержимому), а не `MenuBarExtra`: `MenuBarExtra` нельзя закрыть из кода — `orderOut` рассинхронизирует его состояние, а программный `performClick` по кнопке значка он игнорирует (проверено). При открытии — `NSApp.activate()`. Фон панели сплошной (`windowBackgroundColor`), как в LocalAIBar. Иконка `desktopcomputer` в режиме Mac и `iphone`/`ipad` (по типу устройства) в режиме Устройство.
- Подвал панели — как в LocalAIBar: кнопки без рамки мелким шрифтом «♥ Поддержать» (розовая), «Обновления», справа версия `vX.Y.Z` и «Выход».
- Выход: `NSApplication.willTerminateNotification` → синхронный release (показать курсор, `CGAssociate…(1)`, пустые отчёты, `UKM_HID_SET_ENABLED 0` с ожиданием ответа до 300 мс). При запуске приложение шлёт `UKM_HID_SET_ENABLED 1`.

### D15. Прошивка: свои файлы + патчи к зафиксированному апстриму
- `firmware/UPSTREAM` — URL и коммит апстрима (`RfidResearchGroup/ChameleonUltra@4c5bc2cb6b023d23f7bbc383c9b2b5e39f95419e`, 2026‑10‑31).
- `firmware/src/` — новые файлы, копируются в `firmware/application/src/` апстрима: `ukm_hid.c/.h` (сервис HID, реклама в режиме HID, обработчики команд 6000–6004, событие состояния, нейтральные отчёты при потере USB), `ukm_report_map.h`.
- `firmware/patches/*.patch` — минимальные правки апстрима: Makefile (новые исходники, `ble_hids`, `ble_dis`), `sdk_config.h` (`BLE_HIDS_ENABLED`, `BLE_DIS_ENABLED`, `NRF_SDH_BLE_GATTS_ATTR_TAB_SIZE` 1408 → 2048 — запас под HID и DIS, переполнение дало бы `NO_MEM` и цикл перезагрузок), `application.ld` (начало RAM приложения сдвинуто на те же +0x280: 0x20002ae8 → 0x20002d68, конец RAM и noinit‑область не меняются), `ble_main.c/.h` (сервисы HID/DIS, сопряжение в режиме HID, смена рекламы), `app_cmd.c` (команды 9000–9004), `usb_main.c` (нейтральные отчёты при закрытии порта / пропаже питания).
- `scripts/firmware-build.sh`: клонирует апстрим на зафиксированном коммите в `build/firmware-src/`, копирует `firmware/src/`, применяет патчи (`git apply --check` перед применением), собирает `ultra-dfu-app.zip` теми же шагами, что `build.sh` апстрима для пакета приложения (`make` в `application` и `nrfutil nrf5sdk-tools pkg generate` с ключом апстрима, `--hw-version 0`, `--sd-req 0x0100`). Сам `build.sh` на macOS не запускается: shebang `#!/bin/env bash` и `mergehex` из nRF Command Line Tools для полного образа. Инструменты на macOS: Arm GNU Toolchain 12.2 для darwin‑arm64 (`GNU_INSTALL_ROOT`), `nrfutil` + `nrfutil install nrf5sdk-tools device`. Без Docker.
- Патчи — GPL‑3.0, как апстрим; приложение Mac — отдельная программа, общающаяся только по USB‑serial.

*Почему не своя прошивка с нуля:* Peer Manager, батарея, USB‑CDC и DFU уже отлажены в апстриме, а пользователь сохраняет функции Chameleon.
*Почему не форк на GitHub:* патчи на зафиксированный коммит не требуют внешних репозиториев и показывают в ревью ровно наши изменения.

### D16. Прошивка и откат
- `scripts/firmware-flash.sh`: переводит Chameleon в DFU командой апстрима (`resource/tools/enter_dfu.py` по serial; запасной путь — выключить, зажать кнопку B и подключить USB, светодиоды 4 и 5 мигают), ждёт `1915:521f`, прошивает `nrfutil device program --firmware ultra-dfu-app.zip --traits nordicDfu`.
- Обновляется только приложение (`dfu-app`), загрузчик и SoftDevice не трогаются — устройство всегда можно вернуть в DFU и прошить заново.
- Откат: `scripts/firmware-flash.sh --official` прошивает `ultra-dfu-app.zip` из официального релиза апстрима (скачивается по зафиксированному тегу).
- Первая прошивка выполняется только после явного согласия пользователя.

### D14. Схема расположения в панели
- `DisplayLayoutProvider`: `CGGetActiveDisplayList` → для каждого дисплея `CGDisplayBounds` (глобальные координаты, та же раскладка, что в настройках мониторов), UUID и признак главного (`CGDisplayIsMain`). Обновляется по `CGDisplayRegisterReconfigurationCallback`.
- `ArrangementView` (около 360×220 pt в панели): общий bounding box дисплеев и устройства вписывается с полями, масштаб единый. Дисплеи — скруглённые прямоугольники без hit‑testing, главный отмечен полоской меню. Устройство — прямоугольник с иконкой и подписью; `DragGesture` двигает его свободно, на `onEnded` — `ArrangementLayout.snap` (D8) и анимация к результату. Зона — подсвеченный отрезок на краю дисплея. Клик выбирает устройство (обводка). Кнопка поворота (`rotate.right`) — прямо на прямоугольнике устройства. Под схемой — сегмент «+ / −» в стиле списков macOS: «+» открывает небольшую форму в той же панели (тип Телефон/Планшет + имя) и недоступна, пока на схеме есть устройство (подсказка о лимите); «−» удаляет выбранное устройство и недоступна без выбора. Для выбранного устройства под схемой — слайдер «Скорость указателя» (0,25×…4×, логарифмическая шкала, значение 1× отмечено) и строка с текущей настройкой Mac: «Ускорение мыши на Mac: вкл./выкл.».
- **Визуальные состояния** (одна таблица стилей в `ArrangementStyle`, чтобы состояния не расходились):

  | Элемент / состояние | Вид | Курсор | Hit‑testing |
  |---|---|---|---|
  | Дисплей Mac | миниатюра обоев (`NSWorkspace.desktopImageURL(for:)`, уменьшенная и закешированная) с `saturation 0.35` и `opacity 0.6`, тонкая серая рамка, полоска меню на главном, подпись с именем (`NSScreen.localizedName`) | стрелка | только `.help(...)`, без жестов и выбора |
  | Устройство | заливка `.background`, рамка 1.5 pt `accentColor`, иконка SF Symbol (`iphone`/`ipad`, повернутая по ориентации), имя, точка статуса (зелёная/серая) | `openHand` при наведении | да |
  | Устройство, наведение | лёгкая подсветка `accentColor.opacity(0.12)` | `openHand` | да |
  | Устройство, выбрано | рамка 3 pt `accentColor` + внешнее кольцо 2 pt `accentColor.opacity(0.35)` | `openHand` | да |
  | Устройство, перетаскивается | `scaleEffect 1.04`, тень, `opacity 0.85` | `closedHand` | да |
  | Призрачный контур прилипания | пунктирная рамка `accentColor` без заливки, на месте результата `ArrangementLayout.snap`, который пересчитывается на каждом `onChanged` | — | нет |
  | Зона передачи | сплошной отрезок 3 pt `accentColor` на краю дисплея; во время перетаскивания — пунктиром для предварительной зоны | — | нет |

  Курсоры — `NSCursor.push/pop` через `.onHover` и `onContinuousHover`. Обои обновляются по `NSWorkspace.activeSpaceDidChangeNotification` и при смене конфигурации дисплеев. Если миниатюру получить нельзя, используется нейтральная серая заливка. Тёмная и светлая темы берутся из системных цветов.
- `HotkeyRecorderView`: пока идёт запись, локальный `NSEvent.addLocalMonitorForEvents(.keyDown)` получает сочетание, проверяет его через `Hotkey.isValid` и сохраняет; `Esc` без модификаторов отменяет запись. Запись возможна только в режиме Mac (в режиме Устройство панель открыть мышью нельзя).
- Чтобы перетаскивание и ввод работали в панели агентского приложения, при её открытии вызывается `NSApp.activate()`.

### D17. Обновления: Sparkle + GitHub Releases (как в EnhanceCapCut)
- Зависимость `https://github.com/sparkle-project/Sparkle` `exact: 2.10.0`, только в таргете приложения. `SPUStandardUpdaterController(startingUpdater: true, …)` создаётся, только если приложение запущено из `.app`: у сборки через `swift run` нет Info.plist с лентой.
- Info.plist: `SUFeedURL = https://github.com/DeMoZ/UniversalKM/releases/latest/download/appcast.xml`, `SUEnableAutomaticChecks = true` (интервал по умолчанию — сутки), `SUPublicEDKey` — публичная половина ключа, созданного `generate_keys --account UniversalKM`. Приватная половина остаётся в связке ключей пользователя, а её копия лежит в секрете репозитория `SPARKLE_PRIVATE_KEY`. Ключ не печатается: экспорт идёт во временный файл с правами 600 и сразу через stdin в `gh secret set`, затем файл удаляется.
- `scripts/build-app.sh` копирует `Sparkle.framework` в `Contents/Frameworks`, добавляет `@executable_path/../Frameworks` в rpath и подписывает изнутри наружу (`Installer.xpc`, `Downloader.xpc` с `--preserve-metadata=entitlements`, `Autoupdate`, `Updater.app`, фреймворк, приложение). С флагом `--zip` собирает `build/UniversalKM-<версия>.zip` (`ditto -c -k --keepParent`).
- Формат обновления — zip с `.app`, а не pkg: приложение одно, без компонентов вне бандла.
- Без сертификата (подпись ad‑hoc) hardened runtime не включается: его проверка библиотек требует Team ID, и dyld отказывается грузить `Sparkle.framework` («different Team IDs», проверено) — как в EnhanceCapCut. С настоящим сертификатом — `--options runtime --timestamp`.
- `CFBundleDevelopmentRegion = ru` и `CFBundleLocalizations = [ru]`: окна Sparkle показываются по‑русски, как остальной интерфейс.
- `scripts/appcast.sh <zip>` подписывает архив (`sign_update`: ключ из `$SPARKLE_PRIVATE_KEY` или из связки ключей) и пишет `build/appcast.xml`. Описание версии берётся из `docs/releases/v<версия>.md`, как в EnhanceCapCut.
- `.github/workflows/release.yml` запускается по тегу `v*` на `macos-26`: сверяет тег с `CFBundleShortVersionString`, запускает `swift test`, `scripts/build-app.sh --zip`, `scripts/firmware-build.sh` (ставит Arm GNU Toolchain и nrfutil), `scripts/appcast.sh`. Затем `gh release create` с zip, `appcast.xml` и `chameleon-ultra-hid-dfu-app-<версия>.zip`.
- Выход ради обновления проходит обычный путь `willTerminate` (D13), поэтому ввод возвращается на Mac до перезапуска.
- Подпись кода. Пока сертификата Developer ID нет, архив подписан ad‑hoc. Sparkle проверяет подпись EdDSA, этого достаточно для безопасной доставки. Но после каждого обновления macOS сбросит разрешения Accessibility и Input Monitoring (TCC) — это записано в README и снимается сертификатом.

### D18. Донаты (порт из EnhanceCapCut)
- Core: `Donations` (`LocalizedText`, `DonationMethod`, `DonationInfo.parse`, `Donations.download/cached`) — перенос из EnhanceCapCut. Файл `universalkm.json`, кеш `~/Library/Caches/UniversalKM/donations.json`, User-Agent `UniversalKM`, тайм‑аут 10 с, только `https`.
- Приложение — интерфейс как в LocalAIBar (утилита пользователя для локальной ИИ): `DonateModel` (кеш показывается сразу, загрузка при каждом открытии раздела, `isLoading`), `DonateView` — раздел внутри панели вместо основного содержимого: заголовок «Поддержать UniversalKM» с индикатором загрузки и крестиком, обращение, способы — строки‑кнопки на `pink.opacity(0.12)`, клик открывает `NSWorkspace.open(url)`. Отдельного окна и анимированной кнопки (вариант EnhanceCapCut) нет — так попросил пользователь.
- Тексты интерфейса — русские. Тексты из файла выбираются для `["ru"] + Locale.preferredLanguages` (язык интерфейса первым, как в EnhanceCapCut), чтобы окно не смешивало русский интерфейс с английскими текстами на macOS с английским языком.
- Автоматического предложения доната нет. В EnhanceCapCut его показывают после экспорта, а у UniversalKM нет «завершённой работы». Окно, всплывающее само по себе в фоновой утилите, мешало бы, тем более во время захвата ввода.
- `universalkm.json` добавляется в DeMoZ/donations отдельным PR, из worktree от `origin/main`: в общей копии репозитория работает другая ветка. Способы доната и формулировки — как у EnhanceCapCut (Tribute и CloudTips), обращение — про UniversalKM.

## Risks / Trade-offs

- **[Неудачная прошивка Chameleon]** → обновляется только приложение, загрузчик остаётся; вход в DFU кнопкой B работает при любой прошивке приложения; откат официальным пакетом (D16). Перед первой прошивкой — сборка и проверка неизменённого апстрима тем же скриптом.
- **[Патчи перестанут накладываться на новый апстрим]** → апстрим зафиксирован коммитом; обновление коммита — отдельная задача с перепроверкой.
- **[iOS прячет экранную клавиатуру, пока подключена аппаратная]** → пока приложение работает, Chameleon остаётся подключён к телефону. Если это мешает, позже можно добавить отключение HID в режиме Mac (ценой 1–2 с на переподключение). При выходе из приложения режим HID выключается (D13).
- **[Сопряжение по PIN]** → если в Chameleon включён статический PIN, телефон его спросит; в README — где PIN задаётся и как выключить.
- **[Штатное мобильное приложение Chameleon не подключается]** → одно BLE‑соединение: при подключённом телефоне‑хосте штатное приложение недоступно, пока режим HID не выключен. Штатный USB‑клиент на Mac и UniversalKM не могут держать порт одновременно.
- **[Курсор не скрывается из фонового агента]** → см. D9, поэтапные варианты. Функционально захват работает и с видимым курсором.
- **[Secure Event Input: когда на Mac в фокусе поле пароля, нажатия клавиш могут не проходить через tap]** → проверять `IsSecureEventInputEnabled()` и показывать предупреждение в меню. Мышь при этом работает.
- **[Ввод «застрял» в захвате из‑за бага]** → горячая клавиша обрабатывается первой в колбэке, до всей остальной логики. При падении процесса macOS сама снимает tap. При `tapDisabled*` — release. Кнопка в меню доступна мышью только в local, поэтому главная страховка — горячая клавиша.
- **[Устройство накладывает своё ускорение поверх ускорения Mac]** Android и iOS ускоряют относительное движение HID‑мыши, и отключить это с нашей стороны нельзя. Из‑за двойного ускорения быстрые движения на устройстве могут быть «резче», чем на Mac → слайдер скорости устройства (D10). В README — совет выключить ускорение на устройстве, где это возможно (на Android 14+ «Ускорение указателя» в настройках мыши; на iOS есть только «Скорость отслеживания» в AssistiveTouch). Ручная проверка 2.7 сравнивает ощущение при включённом и выключенном ускорении на Mac.
- **[Задержка: USB‑CDC + BLE 7.5–30 мс на connection interval]** → слияние движения (D5) убирает накопление очереди; прошивка запрашивает минимальный connection interval 7.5 мс в режиме HID. Курсор на телефоне может быть заметно «тяжелее» локального — это принятый компромисс.
- **[Ad‑hoc подпись сбрасывает разрешения]** → `build-app.sh` по умолчанию использует Apple Development и предупреждает при fallback. После каждого обновления через Sparkle без сертификата Developer ID разрешения придётся выдать снова (D17); README предупреждает об этом.
- **[Сеть недоступна или GitHub режет запросы]** → обновления просто не находятся; для донатов есть зеркало jsDelivr и кеш (D18).
- **[Потеря приватного ключа Sparkle]** → существующие установки не смогут принять новые обновления. Ключ хранится в связке ключей и в секрете репозитория; README описывает, как сделать резервную копию (`generate_keys -x`).
- **[iOS без AssistiveTouch]** → курсора нет, клавиатура работает. Подсказка в меню и README.

## Migration Plan

Новое приложение, миграции данных нет. Откат — выйти из приложения (курсор возвращается) и удалить `UniversalKM.app`; Chameleon вернуть на официальную прошивку (`scripts/firmware-flash.sh --official`, D16). Сопряжение на телефоне удаляется через «Забыть устройство», на Chameleon — штатной командой удаления bonds. Выданные разрешения отзываются в System Settings → Privacy & Security или командой `tccutil reset Accessibility com.universalkm.UniversalKM`.

## Open Questions

- Подбор чисел: шаг прокрутки в пикселях на «щелчок», VID/PID в PnP ID, точные пропорции прямоугольников устройств, размеры очереди отчётов. Подбираются на устройстве, на спеки и задачи не влияют.

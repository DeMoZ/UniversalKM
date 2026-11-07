# Design

## Context

Проект пустой (README + OpenSpec). Зачем он нужен — см. proposal.md, раздел «Why». Требования — в `specs/`.

Окружение разработки: macOS 27, Xcode 27.1, Swift 6.4, Apple Silicon. Генераторов Xcode‑проектов (xcodegen, tuist) нет.

Ограничения платформы, которые определяют решения ниже:

- **CoreBluetooth в роли Peripheral** даёт только высокоуровневый API. Рекламировать можно лишь `LocalName` и `ServiceUUIDs` (без Appearance и без флагов). Для `CBMutableDescriptor` официально поддерживаются только 0x2901 (User Description) и 0x2904 (Presentation Format), а HOGP нужен Report Reference (0x2908). Отдельного колбэка об отключении центрального устройства нет. Имя подключённого центрального устройства недоступно — есть только `CBCentral.identifier`.
- **Event tap, который блокирует события** (`.defaultTap`), требует разрешения Accessibility. Только чтение событий (`.listenOnly`) требует Input Monitoring. В App Sandbox фильтрующий tap не работает.
- **TCC‑разрешения** привязаны к подписи кода. Если каждая сборка подписана ad‑hoc, macOS считает её новым приложением и сбрасывает разрешения.
- **iOS** показывает курсор BLE‑мыши только при включённом AssistiveTouch (на iPadOS курсор поддерживается сразу). Android 9+ поддерживает HOGP мышь + клавиатуру без настроек.

## Goals / Non-Goals

**Goals:**
- Первым делом проверить, что macOS 14+ позволяет опубликовать рабочий HOGP‑сервис, и только потом строить остальное.
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
- `UniversalKMCore` (library) — чистая логика без CoreBluetooth и без event tap: `HIDReportDescriptor`, `HIDReports` (кодирование), `KeyCodeMap` (virtual keycode macOS → HID Usage), `DeviceArrangement` + `ArrangementLayout` (модель, прилипание, зона передачи), `HandoffZoneDetector`, `Hotkey` (модель, проверка допустимости, сопоставление), `CaptureStateMachine`, `MouseAccumulator`.
- `UniversalKM` (executable) — `UniversalKMApp.swift`, `BluetoothHIDServer.swift`, `InputManager.swift`, `PermissionsManager.swift`, `DisplayLayoutProvider.swift`, `AppStateManager.swift`, `MenuBarView.swift`, `ArrangementView.swift`, `HotkeyRecorderView.swift`.
- `UniversalKMCoreTests` — тесты на XCTest или Swift Testing.

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
| `NSBluetoothAlwaysUsageDescription` | «UniversalKM работает Bluetooth‑клавиатурой и мышью для вашего телефона.» | без этого ключа процесс падает при первом обращении к Bluetooth |

Для Accessibility и Input Monitoring ключей в Info.plist нет — они выдаются в System Settings. `NSBluetoothPeripheralUsageDescription` устарел и на macOS не нужен.
`Resources/UniversalKM.entitlements`: без App Sandbox, hardened runtime. Для Bluetooth без песочницы entitlements не нужны (`com.apple.security.device.bluetooth` требуется только в песочнице).

### D3. GATT‑структура HOGP
Сервисы:
- **HID 0x1812**:
  - HID Information 0x2A4A — read, `[0x11,0x01, 0x00, 0x02]` (bcdHID 1.11, country 0, флаг NormallyConnectable).
  - Report Map 0x2A4B — read, encrypted.
  - HID Control Point 0x2A4C — write without response.
  - Protocol Mode 0x2A4E — read / write without response, значение 0x01 (Report).
  - Report 0x2A4D (input, клавиатура, ID 1) — read/notify, encrypted.
  - Report 0x2A4D (output, светодиоды клавиатуры, ID 1) — read/write/write without response, encrypted.
  - Report 0x2A4D (input, мышь, ID 2) — read/notify, encrypted.
  - Каждый Report — с дескриптором Report Reference 0x2908 `[reportID, type]`.
- **Device Information 0x180A**: Manufacturer Name 0x2A29, PnP ID 0x2A50 (vendor source = USB, VID/PID — константы для разработки).
- **Battery 0x180F**: Battery Level 0x2A19 — read/notify, всегда 100.

Шифрование: у характеристик с отчётами `permissions = .readEncryptionRequired` (и `.writeEncryptionRequired` у записываемых). Первое чтение запускает системное сопряжение и bonding через bluetoothd.

*Почему составное устройство с Report ID, а не два периферийных устройства:* CoreBluetooth даёт одну периферию на процесс, а хосты одинаково поддерживают составные HID‑устройства.

### D4. Report Map и формат отчётов
- **Клавиатура, Report ID 1, input, 8 байт:** `[modifiers, reserved, k1..k6]`. Usage Page 0x07, модификаторы 0xE0–0xE7 (биты), коды 0x00–0x65.
- **Клавиатура, Report ID 1, output, 1 байт:** 5 бит светодиодов + 3 бита паддинга. Принимается и игнорируется.
- **Мышь, Report ID 2, input, 7 байт:** `[buttons(5 бит + 3 паддинг), x int16 LE, y int16 LE, wheel int8, pan int8]`. X/Y — Logical −32767..32767, Relative. Wheel — Generic Desktop 0x38. Pan — Consumer 0x0238 (AC Pan).

16‑битные X/Y вместо классических 8‑битных: быстрое движение мыши на Mac легко превышает ±127 за событие, а дробить его на несколько отчётов значит тратить слоты BLE. Android и iOS 16‑битные относительные поля поддерживают.
Байты Report Map — константа в `UniversalKMCore`, сверяемая golden‑тестом. Корректность проверяется на устройстве в шаге 1.

### D5. Доставка отчётов: свой serial queue, слияние мыши, очередь клавиатуры
- `CBPeripheralManager` создаётся с собственной `DispatchQueue` (`ble.hid`). Всё состояние сервера живёт только на этой очереди.
- Движение мыши и прокрутка суммируются в `MouseAccumulator` в `Double`. В отчёт идёт целая часть, дробный остаток остаётся до следующего отчёта (D10). Кнопки — текущий bitmask.
- Отчёты отправляются через `updateValue(_:for:onSubscribedCentrals:)`. При `false` ждём `peripheralManagerIsReady(toUpdateSubscribers:)`, а пока ждём, новые движения продолжают суммироваться. Остаток сверх int16 переносится в следующий отчёт (так выполняется требование «без потерь»).
- Отчёты клавиатуры **не** сливаются — их порядок важен (down/up). Они идут через FIFO и при доставке имеют приоритет над мышью.
- Изменение кнопки мыши сбрасывает накопленное движение в отдельный отчёт до отчёта с новыми кнопками, иначе клик уедет в сторону.

### D6. Как определяется подключение и имя хоста
Подключение — это подписка центрального устройства на input‑отчёт (`didSubscribeTo`). Отключение — отписка (`didUnsubscribeFrom`), которую CoreBluetooth генерирует и при обрыве связи. Пока подписок нет, идёт реклама. С подписчиком реклама останавливается (поддерживается один хост).
Имя: CoreBluetooth не даёт имя центрального устройства. Решение: имя задаёт пользователь, когда добавляет устройство на схему (D14). Так как на схеме одно устройство, любой подписавшийся хост считается им, и статус — «Подключено к <имя>». `identifier` последнего хоста запоминается в модели устройства — пригодится, когда устройств станет несколько. Если устройство ещё не добавлено, показывается «Подключено к устройству XXXX» (последние 4 символа `identifier`).
*Альтернатива* — IOBluetooth/`system_profiler`: для BLE‑центральных устройств данных нет, отклонено.

### D7. Event tap на отдельном потоке и синхронное решение о захвате
- `CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, …)` с маской: mouseMoved, left/right/otherMouseDown/Up/Dragged, scrollWheel, keyDown, keyUp, flagsChanged. Tap работает на выделенном `Thread` со своим `CFRunLoop`, чтобы не зависеть от загрузки main thread и не попадать под `tapDisabledByTimeout`.
- Колбэк должен вернуть результат (пропустить событие или `nil`) **синхронно**. Поэтому режим (`local`/`remote`) и флаг «хост подключён» хранятся в маленьком потокобезопасном состоянии (`OSAllocatedUnfairLock`), которое колбэк читает без хопов. Переходы, которые запускает tap (край, горячая клавиша), выполняются прямо в колбэке, а затем уведомляют `AppStateManager` через `MainActor`. Переходы, которые запускает приложение (отключение, меню, выход), вызывают потокобезопасный `InputManager.release()`.
- В колбэке нет тяжёлой работы: события переводятся в лёгкие значения и отправляются через `ble.hid` queue `async`.
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
- `AppStateManager`: `@MainActor @Observable`. Владеет `BluetoothHIDServer`, `InputManager`, `PermissionsManager`, `DisplayLayoutProvider`. Публикует `bluetoothStatus`, `mode`, `permissions`, `displays`, `arrangement`, `isArrangementTemporary`, `hotkey`, `hostDisplayName`. Хранит `arrangement` и `hotkey` в `UserDefaults` (JSON) и при каждом изменении передаёт в `InputManager` пересчитанную зону и горячую клавишу.
- `BluetoothHIDServer` и `InputManager` — `final class … : @unchecked Sendable` с явной изоляцией (своя очередь / lock). Причина — колбэки C‑API и делегаты CoreBluetooth с произвольных потоков. Наружу — `AsyncStream`/колбэки, которые `AppStateManager` читает на `MainActor`.
- `UniversalKMApp`: `MenuBarExtra("UniversalKM", systemImage: …)` со стилем **`.window`** — панель с произвольным SwiftUI (схема, перетаскивание, поле записи клавиши), чего не умеет стиль `.menu`. Иконка `desktopcomputer` в режиме Mac и `iphone`/`ipad` (по типу устройства) в режиме Устройство.
- Выход: `NSApplication.willTerminateNotification` → синхронный release (показать курсор, `CGAssociate…(1)`, пустые отчёты, `stopAdvertising`).

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

## Risks / Trade-offs

- **[macOS запрещает 0x1812 или 0x2908 в CBPeripheralManager]** (на iOS HID‑сервис точно заблокирован; на macOS поведение зависит от версии) → первая задача шага 1 — spike без UI: добавить сервисы, рекламу, подключиться с Android через nRF Connect и с iPhone. Если сервис отклонён — **стоп, решение за пользователем**. Варианты: (а) обойтись boot‑характеристиками (0x2A22/0x2A32/0x2A33 — им не нужен Report Reference); (б) внешний BLE‑донгл (ESP32‑S3 или nRF52840 по USB‑serial), на который Mac шлёт готовые отчёты. Для варианта (б) отправка отчётов скрыта за протоколом `HIDTransport`, и модули 2 и 3 менять не придётся.
- **[Телефон уже знает Mac как Bluetooth‑устройство (Handoff, общий Apple ID) и путает адреса]** → проверяем в spike. Если мешает — инструкция «забыть устройство» и уникальное `LocalName`.
- **[Курсор не скрывается из фонового агента]** → см. D9, поэтапные варианты. Функционально захват работает и с видимым курсором.
- **[Secure Event Input: когда на Mac в фокусе поле пароля, нажатия клавиш могут не проходить через tap]** → проверять `IsSecureEventInputEnabled()` и показывать предупреждение в меню. Мышь при этом работает.
- **[Ввод «застрял» в захвате из‑за бага]** → горячая клавиша обрабатывается первой в колбэке, до всей остальной логики. При падении процесса macOS сама снимает tap. При `tapDisabled*` — release. Кнопка в меню доступна мышью только в local, поэтому главная страховка — горячая клавиша.
- **[Устройство накладывает своё ускорение поверх ускорения Mac]** Android и iOS ускоряют относительное движение HID‑мыши, и отключить это с нашей стороны нельзя. Из‑за двойного ускорения быстрые движения на устройстве могут быть «резче», чем на Mac → слайдер скорости устройства (D10). В README — совет выключить ускорение на устройстве, где это возможно (на Android 14+ «Ускорение указателя» в настройках мыши; на iOS есть только «Скорость отслеживания» в AssistiveTouch). Ручная проверка 2.7 сравнивает ощущение при включённом и выключенном ускорении на Mac.
- **[Задержка BLE 7.5–30 мс на connection interval]** → слияние движения (D5) убирает накопление очереди. Курсор на телефоне может быть заметно «тяжелее» локального — это принятый компромисс.
- **[Ad‑hoc подпись сбрасывает разрешения]** → `build-app.sh` по умолчанию использует Apple Development и предупреждает при fallback.
- **[iOS без AssistiveTouch]** → курсора нет, клавиатура работает. Подсказка в меню и README.

## Migration Plan

Новое приложение, миграции данных нет. Откат — выйти из приложения (курсор возвращается) и удалить `UniversalKM.app`. Сопряжение на телефоне удаляется через «Забыть устройство». Выданные разрешения отзываются в System Settings → Privacy & Security или командой `tccutil reset Accessibility com.universalkm.UniversalKM`.

## Open Questions

- Подбор чисел: шаг прокрутки в пикселях на «щелчок», VID/PID в PnP ID, точные пропорции прямоугольников устройств. Подбираются на устройстве, на спеки и задачи не влияют.
- Нужен ли iOS обязательно сервис Battery, или достаточно Android‑минимума. На план не влияет: Battery сервис добавляется в любом случае.

# Tasks

Исходная точка — проверки 2026‑11‑09 на Samsung S10e: AOA 2 по USB (мышь и клавиатура через libusb) и ADB по Wi‑Fi через `/system/bin/hid` (мышь, клавиатура, RTT 8 мс). Решения пользователя: `adb` пользователя, оба способа Wi‑Fi (сопряжение по коду и `adb tcpip`), Android по USB и Wi‑Fi — основные, Chameleon — после них.

## 1. Спайк USB: IOKit и поведение Android

- [x] 1.1 Пробник на IOKit (`scripts/aoa-probe.c` + C‑модуль `Sources/UKMUSB`: UUID‑макросы плагинов IOKit в Swift не импортируются; design D2): найти устройство через `IOServiceMatching("IOUSBHostDevice")`, получить `IOUSBDeviceInterface`, без `USBDeviceOpen` выполнить `GET_PROTOCOL`, зарегистрировать мышь, подвигать курсор, снять регистрацию. Проверка: на Samsung курсор движется по квадрату без root и без libusb. Если IOKit отказывает — записать код ошибки в design D2 и перейти на libusb до группы 3.
- [x] 1.2 В пробнике зарегистрировать одно HID с составным `HIDReportDescriptor.reportMap` и слать отчёты с Report ID (design D4). Проверка: курсор, набор «Hello 123» и прокрутка работают. Если составной дескриптор не принят — записать в D4 и использовать два HID.
- [x] 1.3 Режимы USB на Samsung («Передача файлов», «Только зарядка», «Модем», с отладкой и без): интерфейсы в `ioreg`, PID, серийный номер, ответ `GET_PROTOCOL`. Проверка: таблица режимов в Context design.md; правило опроса D4 уточнено при необходимости.
- [x] 1.4 Результаты спайка — в память проекта (`android-aoa-usb-hid-works`). Проверка: файл памяти обновлён.

## 2. Core: AOA, команды hid, реестр peer ID

- [x] 2.1 `AOAHID.swift`: константы запросов 51/54–57, события `[reportID] + bytes` из `KeyboardReport`/`MouseReport`, признак «похоже на Android» по интерфейсам, vendor ID и PID с исключениями Apple и Chameleon (design D4). Проверка: unit‑тесты — байты событий; Samsung MTP/ADB и Google AOA PID → да; `05ac:139f`, `6868:8686`, USB‑мышь → нет.
- [x] 2.2 `HidCommand.swift`: JSON‑строки `register` (с `bus` и без) и `report` для `/system/bin/hid` (design D5). Проверка: unit‑тесты — строка `register` содержит дескриптор из `reportMap` числами, `report` — `[1, …]`/`[2, …]`, одна строка на команду без переводов строк внутри.
- [x] 2.3 `AndroidPeerRegistry` (design D3): peer ID из `0x8000…0x80FE` по серийному номеру, ключ `usb-loc:` без серийного, кодирование для UserDefaults, `isAndroidPeer(_:)`. Проверка: unit‑тесты — тот же серийный → тот же ID после round‑trip; переполнение → nil; ID Chameleon (`0…0x7FFF`, `0xFFFF`) не Android.

## 3. Android‑транспорт: каркас и USB‑канал

- [x] 3.1 `AndroidUSBDeviceWatcher.swift`: появление и пропажа `IOUSBHostDevice`, vendor/product/серийный/интерфейсы, фильтр 2.1, `GET_PROTOCOL` (design D2, D4). Проверка: в журнале `scripts/run.sh` при подключении Samsung — «AOA 2, available» за ≤ 2 с; Chameleon и кейс Apple — без запросов AOA; выдёргивание — «gone».
- [x] 3.2 `AOALink.swift` и `AndroidHIDTransport.swift` (`HIDTransport`, design D1, D4, D6): хосты по peer ID, каналы, регистрация только для привязанных peer ID при `setEnabled(true)`, очередь клавиатуры без потерь, слияние мыши (`MouseAccumulator`, 250 Гц), `sendNeutral`, снятие, `shutdown(timeout:)` ≤ 0,3 с, `UNREGISTER_HID` при запуске; `AndroidStatus` через обработчик. Проверка: `scripts/run.sh --ble-demo` рисует квадрат, щёлкает и печатает «hello» на Samsung по USB без Chameleon.
- [x] 3.3 Ошибки и отключение USB (design D5, D7): `NoDevice/NotResponding` и `kIOTerminatedNotification` → канал потерян; тот же серийный снова → регистрация. Проверка: 5 раз выдернуть и вставить кабель во время демо — демо продолжается; смена режима USB — снова `registered` с тем же peer ID.

## 4. Два транспорта в приложении

- [ ] 4.1 `CompositeHIDTransport.swift` (design D1): маршрутизация по `isAndroidPeer`, `start/setEnabled/shutdown` обоим; `AppDelegate` создаёт оба и отдаёт составной `AppStateManager`, `InputManager`, `BLEDemo`. Проверка: `scripts/build-app.sh`; с Chameleon всё как в 0.1.4 (вручную: телефон через Chameleon, пересечение края, возврат).
- [x] 4.2 `AppStateManager`: `subscribedPeers` = Chameleon + зарегистрированные Android; `unboundHosts` включает доступные Android без привязки; «Добавить», привязка ожидающего, «Перепривязать», удаление → регистрация/снятие через транспорт; имя по умолчанию — модель телефона. Проверка: unit‑тесты привязки для Android peer ID; вручную — впервые воткнутый телефон не теряет экранную клавиатуру, пока его не добавили.
- [ ] 4.3 Отсутствие Chameleon не ошибка (spec `android-usb-link` «Работа без ChameleonUltra»): панель и иконка без ошибки, если Chameleon не используется в схеме или есть Android‑устройства. Проверка: только Samsung по USB, Chameleon отключён — ошибки нет, пересечение края работает.

## 5. Wi‑Fi‑канал (ADB)

- [x] 5.1 `ADBClient.swift` (design D5): поиск `adb` и проверка версии, `start-server`, `track-devices` (или опрос `devices -l`), `getprop ro.serialno`/модель для новых устройств, `pair`, `connect`, `mdns services`, `tcpip` с адресом из `ip addr`. Проверка: в журнале — список устройств с серийными номерами и способом (usb/wifi); без `adb` — статус `adbPath = nil`, приложение работает.
- [x] 5.2 `ADBLink.swift` (design D5, D6): процесс `adb shell hid -`, регистрация (повтор без `bus`), отчёты JSON со слиянием мыши 125 Гц, снятие через нейтральные отчёты и закрытие stdin, выход процесса = потеря. Подключение в `AndroidHIDTransport`: ADB‑канал хоста по серийному, AOA приоритетнее (D1). Проверка: Samsung только по Wi‑Fi — `scripts/run.sh --ble-demo` рисует квадрат и печатает «hello»; запрос «Локальная сеть» от macOS — записать в design (есть/нет).
- [x] 5.3 Переход и потеря (design D5, D7; spec `android-wifi-link` «Один телефон по USB и по Wi‑Fi», «Потеря Wi‑Fi»): USB → Wi‑Fi при выдёргивании без возврата курсора, Wi‑Fi → USB при вставке, потеря Wi‑Fi ≤ 3 с, переподключение по запомненному адресу и mDNS раз в 5 с. Проверка: вручную на Samsung — кабель туда‑обратно 3 раза во время набора текста (без потерянных букв и двух клавиатур после перехода), выключение Wi‑Fi на телефоне — курсор на Mac за ≤ 3 с.

## 6. Панель

- [ ] 6.1 `MenuBarView` (spec «Способ подключения в панели»): у устройства «USB» / «Wi‑Fi» / «Bluetooth через Chameleon» / «не подключено»; предложения «Добавить» для Android первыми; статус Chameleon второй строкой. Проверка: скриншот панели с телефоном по USB и по Wi‑Fi.
- [x] 6.2 Блок «Android по Wi‑Fi» (spec `android-wifi-link`): подсказка установки `adb`; «Сопрячь по коду» (IP:порт + код, ошибки); «Включить Wi‑Fi» у телефона на кабеле с отладкой; подсказка после перезагрузки телефона в режиме tcpip. Проверка: вручную — сопряжение по коду на Samsung (Android 12) и `tcpip` проходят из панели; неверный код показывает ошибку.
- [x] 6.3 Строки 6.1–6.2 на всех 10 языках интерфейса. Проверка: все ключи есть в каждом `Resources/*.lproj/Localizable.strings` (скрипт сравнения ключей без расхождений).

## 7. Документация

- [x] 7.1 README.md по design D8: шапка и Features, «How it works» с тремя способами, разделы «Android over USB» и «Android over Wi‑Fi (ADB)», затем блок Chameleon с существующими разделами; уточнить фразу про libusb. Проверка: якоря `](#…)` ведут на существующие заголовки, текст разделов Chameleon сохранён.
- [x] 7.2 README.ru.md — та же структура на русском. Проверка: заголовки двух README совпадают по порядку (`grep '^#'`).
- [x] 7.3 `docs/images/architecture.svg`: три пути (кабель → Android, Wi‑Fi → Android, Chameleon → Bluetooth → Android/iPhone/iPad), светлая и тёмная тема. Проверка: схема читается в обеих темах в браузере.
- [x] 7.4 Заметки к релизу `docs/releases/v<следующая>.md`. Проверка: файл есть, версия совпадает с `Resources/Info.plist` на момент релиза.

## 8. Проверка целиком

- [ ] 8.1 Сценарии обеих спецификаций вручную на Samsung (и на втором Android, если есть), с Chameleon и без. Проверка: каждый сценарий отмечен «работает» или с описанием отклонения в этом файле; отклонения исправлены или вынесены в задачи.
- [ ] 8.2 `swift test` и `scripts/build-app.sh --zip` проходят. Проверка: вывод без ошибок.

## Workflow follow-up

- PR из ветки `add-android-usb-transport`, merge в `main` — пользователем.
- Архивировать изменение после merge.

# Tasks

Исходная точка — проверка 2026‑11‑09: Samsung `04e8:6860` отвечает AOA 2 и принимает мышь и клавиатуру через AOA2 HID (пробник на libusb). Изменение независимо от `add-chameleon-ble-link`.

## 1. Спайк: USB‑доступ и поведение Android (решающий шаг)

- [ ] 1.1 Пробник на Swift + IOKit (`scripts/aoa-probe.swift`, design D2): найти устройство через `IOServiceMatching("IOUSBHostDevice")`, получить `IOUSBDeviceInterface`, без `USBDeviceOpen` выполнить `GET_PROTOCOL`, зарегистрировать мышь, подвигать курсор, снять регистрацию. Проверка: на Samsung курсор движется по квадрату без root и без libusb. Если IOKit отказывает — записать код ошибки в design D2 и перейти на libusb (`systemLibrary` + dylib в бандле), прежде чем начинать группу 3.
- [ ] 1.2 В пробнике зарегистрировать одно HID с составным `HIDReportDescriptor.reportMap` (Report ID 1 и 2) и послать отчёты с Report ID (design D4). Проверка: на телефоне работают и курсор, и набор «Hello 123», и прокрутка колесом. Если составной дескриптор не принимается — записать в design D4 и использовать два HID (id 1, id 2).
- [ ] 1.3 Проверить на Samsung признаки Android из design D4 в разных режимах USB («Передача файлов», «Только зарядка», «Модем», с отладкой и без): какие интерфейсы видит `ioreg`, меняется ли PID, остаётся ли серийный номер, отвечает ли `GET_PROTOCOL`. Проверка: таблица режимов в Context design.md; правило опроса D4 уточнено, если «Только зарядка» не даёт MTP/ADB.
- [ ] 1.4 Сохранить результаты спайка в памяти проекта (дополнить `android-aoa-usb-hid-works`). Проверка: файл памяти обновлён.

## 2. Core: AOA и ID USB‑хостов

- [ ] 2.1 `AOAHID.swift` в `UniversalKMCore`: константы запросов 51/54–57, построение событий (`[reportID] + bytes` из `KeyboardReport`/`MouseReport`), признак «похоже на Android» по списку интерфейсов, vendor ID и PID (design D4) с исключениями Apple и Chameleon. Проверка: unit‑тесты — байты событий клавиатуры и мыши; Samsung MTP/ADB, Google AOA PID → да; `05ac:139f`, `6868:8686`, USB‑мышь → нет.
- [ ] 2.2 `USBPeerRegistry` в Core (design D3): выдача peer ID из `0x8000…0x80FE` по ключу (vendor ID + серийный номер, без серийного — location ID), устойчивость к смене PID, кодирование для UserDefaults, `isUSBPeer(_:)`. Проверка: unit‑тесты — тот же ключ даёт тот же ID после round‑trip; смена PID не меняет ID; переполнение диапазона → nil; ID Chameleon (`0…0x7FFF`, `0xFFFF`) не считаются USB.

## 3. Транспорт Android по USB

- [ ] 3.1 `AndroidUSBDeviceWatcher.swift`: уведомления о появлении и пропаже `IOUSBHostDevice`, чтение vendor/product/серийного номера/интерфейсов, фильтр из 2.1, `GET_PROTOCOL` на очереди транспорта (design D2, D4). Проверка: в журнале (`scripts/run.sh`) при подключении Samsung — «AOA 2, detected» за ≤ 2 с; при подключении Chameleon и кейса Apple — без запросов AOA; при выдёргивании — «gone».
- [ ] 3.2 `AndroidUSBTransport.swift` (`HIDTransport`, design D1, D4, D5): состояния `detected / registered / unsupported`, регистрация только для привязанных peer ID и при `setEnabled(true)`, очередь клавиатуры без потерь, слияние мыши через `MouseAccumulator` с потолком 250 Гц, `sendNeutral`, снятие регистрации, `shutdown(timeout:)` ≤ 0,3 с, `UNREGISTER_HID` перед регистрацией после запуска. Статус `AndroidUSBStatus` через обработчик. Проверка: `scripts/run.sh --ble-demo` рисует квадрат, щёлкает и печатает «hello» на Samsung по USB при выключенном Chameleon.
- [ ] 3.3 Обработка ошибок и отключения (design D5, D6): `NoDevice/NotResponding` и `kIOTerminatedNotification` → хост пропадает; повторное появление того же ключа → регистрация заново. Проверка: на телефоне выдернуть и вставить кабель 5 раз во время демо — после каждого возврата демо продолжается, приложение не падает; смена режима USB на телефоне — устройство снова `registered` с тем же peer ID.

## 4. Два транспорта в приложении

- [ ] 4.1 `CompositeHIDTransport.swift` (design D1): маршрутизация по `isUSBPeer`, `start/setEnabled/shutdown` обоим; `AppDelegate` создаёт оба транспорта и отдаёт составной `AppStateManager`, `InputManager` и `BLEDemo`. Проверка: сборка `scripts/build-app.sh`; с одним Chameleon всё работает как в 0.1.4 (ручная проверка: телефон через Chameleon, пересечение края, возврат).
- [ ] 4.2 `AppStateManager`: `subscribedPeers` = хосты Chameleon + `registered` USB; `unboundHosts` включает `detected` USB‑устройства без привязки; добавление предложенного USB‑устройства, привязка ожидающего устройства, «Перепривязать» и удаление вызывают регистрацию/снятие (spec «Подключение только с согласия», «Снятие регистрации»). Имя по умолчанию — имя продукта USB. Проверка: unit‑тесты `DeviceArrangement`/логики привязки для USB peer ID; вручную — телефон, воткнутый впервые, не теряет экранную клавиатуру, пока его не добавили.
- [ ] 4.3 Отсутствие Chameleon не ошибка (spec «Работа без ChameleonUltra»): статус в панели и иконка в строке меню не показывают ошибку, если Chameleon не используется в схеме или есть USB‑устройства. Проверка: только Samsung по USB, Chameleon отключён — панель без ошибки, пересечение края работает.
- [ ] 4.4 Панель (`MenuBarView`, spec «Способ подключения в панели»): у устройства «USB» / «Bluetooth через Chameleon» / «не подключено»; предложение «Android по USB: добавить» первым; статус Chameleon второстепенной строкой. Строки локализованы на все 10 языков интерфейса. Проверка: скриншот панели с устройством по USB и с Chameleon; проверка строк в `Resources/*.lproj` (нет недостающих ключей).

## 5. Документация

- [ ] 5.1 README.md: перестроить по design D7 — шапка и Features с Android по кабелю первым, «How it works» с двумя способами, новый раздел «Android over USB» (что нужно, как добавить, ограничения, проверенные устройства), затем блок «Wireless: ChameleonUltra and similar boards» с существующими разделами; уточнить фразу про libusb. Проверка: все ссылки и якоря README работают (`grep` по `](#`), разделы Chameleon сохранились без потерь текста.
- [ ] 5.2 README.ru.md — та же структура и содержание на русском. Проверка: заголовки двух README совпадают по порядку (сравнить `grep '^#'`).
- [ ] 5.3 `docs/images/architecture.svg`: два пути — Mac → кабель → Android и Mac → Chameleon → Bluetooth → Android/iPhone/iPad; светлая и тёмная тема GitHub. Проверка: открыть README на GitHub в обеих темах (или локально в браузере) — схема читается.
- [ ] 5.4 Заметки к релизу `docs/releases/v<следующая>.md`: Android по кабелю без Chameleon. Проверка: файл есть, версия совпадает с `Resources/Info.plist` на момент релиза.

## 6. Проверка целиком

- [ ] 6.1 Сценарии `specs/android-usb-link/spec.md` вручную на Samsung и на втором Android другого производителя (если есть), с Chameleon и без. Проверка: каждый сценарий отмечен «работает» или с описанием отклонения в этом файле; найденные отклонения исправлены или вынесены в задачи.
- [ ] 6.2 `swift test` и `scripts/build-app.sh --zip` проходят. Проверка: вывод команд без ошибок.

## Workflow follow-up

- PR из ветки `add-android-usb-transport`, merge в `main` — пользователем.
- Архивировать изменение после merge.

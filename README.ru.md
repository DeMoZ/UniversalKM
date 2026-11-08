<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="UniversalKM">
</p>

<h1 align="center">UniversalKM</h1>

<p align="center"><a href="README.md">English</a> · <b>Русский</b></p>

<p align="center">
  <b>Мышь и клавиатура Mac для любого телефона и планшета.</b><br>
  Подведите курсор к краю экрана, и ввод перейдёт на Android, iPad или iPhone, как в Universal Control, только не только для техники Apple.
</p>

<p align="center">
  <a href="https://github.com/DeMoZ/UniversalKM/releases/latest"><img src="https://img.shields.io/github/v/release/DeMoZ/UniversalKM?label=%D1%80%D0%B5%D0%BB%D0%B8%D0%B7&color=3b4cc0" alt="Последний релиз"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-2b3245?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/BLE%20HID-ChameleonUltra-1f9d8a" alt="ChameleonUltra">
</p>

<p align="center">
  <img src="docs/images/panel-ru.png" width="426" alt="Панель UniversalKM: два дисплея Mac и планшет у правого края встроенного дисплея">
</p>

---

## Что умеет

| | |
|---|---|
| 🖱️ **Переход по краю** | Телефон или планшет ставится на схеме к краю любого дисплея. Курсор, упёршийся в этот край, уходит на устройство вместе с клавиатурой. |
| ↩️ **Возврат так же** | Доведите курсор до края устройства, обращённого к Mac, и толкните дальше: ввод вернётся на Mac на той же высоте. ⌃⌥⌘⎋ возвращает всегда. |
| 👻 **Курсор Mac не мешает** | Пока вы управляете устройством, курсор Mac скрыт и стоит на месте. |
| 📱 **До трёх устройств** | Одновременно подключаются три устройства, у каждого своя зона на схеме. |
| 📐 **Реальный размер** | У устройства задаётся размер экрана в точках и пикселях, а прямоугольник тянется за уголок, чтобы на схеме совпал физический размер. |
| 🔌 **USB или Bluetooth** | Chameleon работает по USB. Если кабель выдернуть, приложение продолжает по Bluetooth. |
| 🔄 **Обновления** | Обновления ставятся из приложения (Sparkle, подписанная лента). Разрешения macOS после обновления не сбрасываются. |
| 🌍 **Язык системы** | Интерфейс на языке системы: русский, английский, немецкий, французский, испанский, португальский (Бразилия), итальянский, китайский (упрощённый), японский, корейский. |

## Как это устроено

<p align="center">
  <img src="docs/images/architecture-ru.svg" alt="Mac с UniversalKM подключён к ChameleonUltra по USB‑C (запасной канал — Bluetooth); Chameleon по BLE HID работает клавиатурой и мышью для телефона, планшета и iPhone">
</p>

1. **UniversalKM** живёт в строке меню. Он перехватывает мышь и клавиатуру, когда курсор входит в зону устройства, и отправляет нажатия и движения дальше.
2. **ChameleonUltra** подключён к Mac по USB. Прошивка UniversalKM превращает его в обычную Bluetooth‑клавиатуру и мышь (BLE HID).
3. **Телефон** видит стандартную Bluetooth‑клавиатуру и мышь: никаких приложений на нём не нужно.

## Почему не встроенный Bluetooth Mac

Логично было бы, чтобы Mac сам притворился Bluetooth‑клавиатурой. macOS этого не позволяет:

- **BLE.** `CBPeripheralManager` отказывается публиковать сервис HID `0x1812`, а также Device Information `0x180A` и Battery `0x180F`, с ошибкой *«The specified UUID is not allowed for this operation»*. Без этих сервисов телефон не примет устройство как клавиатуру.
- **Классический Bluetooth.** В IOBluetooth нет поддерживаемого API для роли HID‑устройства: Mac может подключать клавиатуры, но не быть ею.
- **Universal Control** работает только между Mac и iPad Apple ID одного владельца.

### Обычный USB‑донгл тоже не поможет

Кажется, что достаточно воткнуть второй Bluetooth‑адаптер и управлять им напрямую. На macOS так не выйдет:

- macOS работает только со своим Bluetooth‑контроллером, драйверов для сторонних USB‑адаптеров нет;
- захватить USB‑устройство из своей программы мешает ограниченный entitlement `com.apple.vm.device-access`: libusb получает отказ даже от root;
- дешёвые адаптеры «Wi‑Fi + Bluetooth» вроде AIC8800 вообще видны как диск с драйверами для Windows.

Это проверено на адаптере AIC 88M80: в режим Bluetooth он не переключился.

### Что подходит

Нужен отдельный микроконтроллер с Bluetooth LE, который сам ведёт себя как HID‑клавиатура, а с Mac общается по USB‑порту:

| Устройство | Чип | Комментарий |
|---|---|---|
| **ChameleonUltra** | nRF52840 | ✅ Используется в UniversalKM. Свои функции NFC/RFID сохраняет. |
| Nordic nRF52840 Dongle (PCA10059), Seeed XIAO nRF52840, Adafruit Feather nRF52840 | nRF52840 | Тот же чип, что в Chameleon. Нужна своя прошивка с HID. |
| ESP32‑S3 / ESP32‑C3 (любая плата с USB) | ESP32 | Самый дешёвый вариант: BLE HID на NimBLE, связь с Mac по USB‑serial. |
| Raspberry Pi Pico W / Pico 2 W | RP2040 / RP2350 + CYW43439 | BLE HID на BTstack. |

Сейчас приложение поддерживает только ChameleonUltra. Транспорт в коде отделён протоколом `HIDTransport`, поэтому другую плату можно добавить, написав для неё прошивку и транспорт.

## Устройство в этом проекте: ChameleonUltra

[ChameleonUltra](https://github.com/RfidResearchGroup/ChameleonUltra) от RfidResearchGroup — открытый эмулятор и считыватель NFC/RFID‑карт размером с брелок. Внутри **Nordic nRF52840**: Cortex‑M4F и Bluetooth 5, то есть всё нужное для BLE‑клавиатуры. Он уже лежал под рукой, поэтому покупать ESP32 не пришлось.

| | |
|---|---|
| **Модель** | ChameleonUltra, hw v1, USB `6868:8686` |
| **Заводская прошивка** | v2.1.0 (на неё можно откатиться) |
| **Основа прошивки UniversalKM** | апстрим [`4c5bc2cb`](https://github.com/RfidResearchGroup/ChameleonUltra/commit/4c5bc2cb6b023d23f7bbc383c9b2b5e39f95419e) (v2.3.0‑14), nRF5 SDK 17, SoftDevice S140 7.2.0 |
| **Чем прошивали** | `nrfutil` по USB через штатный DFU‑загрузчик Chameleon. Загрузчик не меняется. |
| **Чем собирали** | Arm GNU Toolchain 12.2 и `make`, без Docker (`scripts/firmware-build.sh`) |

### Что добавлено в прошивку

<p align="center">
  <img src="docs/images/firmware-ru.svg" alt="Апстрим ChameleonUltra, свои исходники firmware/src и 8 патчей собираются firmware-build.sh в DFU‑пакет, который nrfutil заливает в Chameleon по USB DFU">
</p>

Свой код лежит в `firmware/src/` (`ukm_hid.c`, `ukm_report_map.h`), а изменения апстрима оформлены восемью небольшими патчами в `firmware/patches/`:

| Патч | Что делает |
|---|---|
| `0001` Makefile | подключает исходники HID и модули SDK `ble_hids`, `ble_dis` |
| `0002` sdk_config | включает HID и Device Information, 3 одновременных соединения, увеличенную таблицу GATT |
| `0003` ble_main | сервисы HID, реклама с именем `ChameleonUltra`, сопряжение без кода, отдельный канал управления для Mac |
| `0004` app_cmd | команды USB 9000–9006: включить режим, отправить клавиатуру или мышь конкретному устройству, список устройств, счётчики |
| `0005` usb_main | если USB выдернули: отпустить все клавиши, а без Bluetooth‑связи с Mac выключить режим |
| `0006` application.ld | сдвигает RAM под SoftDevice с тремя соединениями |
| `0007` app_main | обработчик LESC при выключенном PIN |
| `0008` peer_manager | события сопряжения, которые апстрим пропускал при выключенном PIN |

Отчёты HID: клавиатура (ID 1, 8 байт, плюс светодиоды) и мышь (ID 2, кнопки, 16‑битные X/Y, колесо и горизонтальная прокрутка). Карты, слоты, кнопки и штатный клиент Chameleon продолжают работать. Режим клавиатуры и мыши включается только из приложения.

## Установка

1. Скачайте `UniversalKM-<версия>.zip` из [последнего релиза](https://github.com/DeMoZ/UniversalKM/releases/latest) и перенесите приложение в «Программы». Первый запуск: правый клик → «Открыть».
2. Прошейте Chameleon пакетом `chameleon-ultra-hid-dfu-app-<версия>.zip` из того же релиза (ниже описано, как) или соберите прошивку сами.
3. Дайте разрешения «Универсальный доступ» и Bluetooth.
4. Сопрягите телефон с `ChameleonUltra` в его настройках Bluetooth и поставьте устройство на схеме к нужному краю дисплея (кнопка «+»).

**Требования:** macOS 14 или новее, Apple Silicon. Для сборки нужны Xcode 27 и Swift 6.

## ChameleonUltra: сборка и прошивка

```bash
scripts/firmware-build.sh       # build/ultra-dfu-app.zip
scripts/firmware-flash.sh       # прошить по USB (штатный DFU)
```

- **Сборка.** Скрипт сам ставит Arm GNU Toolchain 12.2 и `nrfutil` в `~/Library/Caches/UniversalKM-firmware-tools`, скачивает прошивку апстрима в `build/firmware-src/`, кладёт туда `firmware/src/` и накладывает `firmware/patches/`.
- **Прошивка.** Закройте штатный клиент Chameleon и UniversalKM: порт может держать только одна программа. Скрипт сам переводит Chameleon в DFU. Если не вышло, выключите Chameleon, зажмите кнопку B и подключите USB (мигают светодиоды 4 и 5), скрипт подождёт.
- **Откат на официальную прошивку:** `scripts/firmware-flash.sh --official` (по умолчанию ставится версия `OFFICIAL_TAG` из `firmware/UPSTREAM`) или `scripts/firmware-flash.sh --official v2.3.0`.

## Сопряжение с телефоном и планшетом

Пока UniversalKM запущен, Chameleon рекламирует себя как Bluetooth‑клавиатуру `ChameleonUltra`. Одновременно к нему подключаются до трёх устройств. Отчёты получает то, на которое передан ввод.

- **Android:** Настройки → Bluetooth → «Добавить устройство» → `ChameleonUltra`. Указатель и клавиатура работают сразу.
- **iPhone / iPad:** Настройки → Bluetooth → `ChameleonUltra`. Клавиатура работает сразу. Курсор мыши iOS показывает только с AssistiveTouch (Универсальный доступ → Касание → AssistiveTouch). С iPhone курсор пока не двигается: это известная проблема, задача 1.16.
- **PIN.** Если в настройках Chameleon включено сопряжение по PIN, телефон спросит его; если выключено (по умолчанию), сопряжение пройдёт без кода. Переключается штатным клиентом Chameleon: `hw settings blepair -e` / `-d`, PIN задаётся командой `hw settings blekey`.
- **Не сопрягайте с Chameleon сам Mac** в настройках Bluetooth. Mac займёт одно из трёх соединений и начнёт получать нажатия. Если уже сопрягли, выберите «Забыть это устройство».
- **Сопряжение запоминается:** после перезапуска приложения или Chameleon устройства подключаются сами. Удалить сопряжение: на телефоне «Забыть устройство», на Chameleon командой `hw settings bleclearbonds`.
- **Когда приложение закрыто,** Chameleon отключает устройства и пропадает из поиска до следующего запуска, а на телефоне возвращается экранная клавиатура.

## USB и Bluetooth между Mac и Chameleon

Приложение само находит Chameleon по USB и параллельно держит с ним Bluetooth‑соединение (штатный канал Nordic UART; это не сопряжение macOS).

- Если USB выдернуть, работа продолжается по Bluetooth. Когда USB вернётся, приложение снова переходит на USB.
- Пока Mac на связи по Bluetooth, он занимает одно из трёх соединений Chameleon, и для устройств остаётся два.
- Если USB выдернули, а Bluetooth‑связи с Mac нет, Chameleon выключает режим клавиатуры и мыши, сам отпускает все клавиши и отключает устройства.

При первом запуске macOS спросит разрешение на Bluetooth, его нужно дать. Ключи `Resources/Info.plist`: `LSUIElement` (только строка меню), `NSBluetoothAlwaysUsageDescription` (Bluetooth‑канал к Chameleon), `SUFeedURL` и `SUPublicEDKey` (обновления).

## Сборка приложения

```bash
scripts/build-app.sh          # build/UniversalKM.app
scripts/build-app.sh --zip    # + build/UniversalKM-<версия>.zip
scripts/run.sh                # собрать, перезапустить и смотреть лог
scripts/run.sh --ble-demo     # демо: квадрат курсором, клик и «hello» на каждом устройстве
```

**Подпись.** macOS привязывает разрешения «Универсальный доступ» и «Мониторинг ввода» к сертификату подписи. Скрипт выбирает сертификат в таком порядке:

1. `SIGN_IDENTITY`, если задан;
2. первая идентичность «Apple Development»;
3. самоподписанный сертификат проекта «UniversalKM Self-Signed» из связки ключей;
4. если сертификата нет, подпись ad‑hoc.

С постоянным сертификатом разрешения переживают пересборки и обновления, с ad‑hoc сбрасываются каждый раз.

- **Сертификат проекта** лежит в связке ключей входа (ключ и сертификат «UniversalKM Self-Signed» на 10 лет) и в секретах репозитория `SIGNING_CERTIFICATE_P12` / `SIGNING_CERTIFICATE_PASSWORD`, ими подписываются релизы. Сделайте резервную копию: «Связка ключей» → «Мои сертификаты» → «UniversalKM Self-Signed» → «Экспортировать…» (.p12 с паролем), и положите её в менеджер паролей. Если сертификат потерять, следующее обновление один раз попросит разрешения заново.
- Самоподписанный сертификат не убирает предупреждение macOS при первом запуске. Это делает только сертификат Apple Developer ID с нотаризацией.

## Обновления и релизы

Приложение само проверяет обновления раз в сутки, а кнопка «Обновления» в подвале панели проверяет сразу. Обновления устанавливает [Sparkle](https://sparkle-project.org): он берёт ленту `appcast.xml` из последнего релиза на GitHub и ставит только архивы, подписанные ключом проекта (EdDSA).

- **Ключ подписи.** Приватная половина лежит в связке ключей (учётная запись `UniversalKM`) и в секрете репозитория `SPARKLE_PRIVATE_KEY`, публичная записана в `SUPublicEDKey` в `Resources/Info.plist`. Если ключ потерять, установленные копии не смогут обновиться. Сделайте резервную копию в менеджер паролей, затем удалите файл:
  ```bash
  .build/artifacts/sparkle/Sparkle/bin/generate_keys --account UniversalKM -x ~/universalkm-sparkle.key
  ```
- **Выпуск версии.** Поднимите `CFBundleShortVersionString` и `CFBundleVersion` в `Resources/Info.plist`, напишите `docs/releases/v<версия>.md`, влейте в `main` и запушьте тег:
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```
  Workflow `.github/workflows/release.yml` проверяет, что тег совпадает с версией, прогоняет тесты, собирает приложение и прошивку Chameleon, подписывает ленту и публикует релиз с `UniversalKM-<версия>.zip`, `appcast.xml` и `chameleon-ultra-hid-dfu-app-<версия>.zip`.
- **Локально без публикации:** `scripts/build-app.sh --zip && scripts/appcast.sh build/UniversalKM-<версия>.zip`. Ключ берётся из связки ключей.

## Поддержать проект

UniversalKM бесплатный. Кнопка «♥ Поддержать» в подвале панели показывает способы поддержки. Они загружаются из [DeMoZ/donations](https://github.com/DeMoZ/donations) (`universalkm.json`), поэтому ссылки меняются без нового релиза.

> План и требования: `openspec/changes/add-ble-hid-input-bridge/`.

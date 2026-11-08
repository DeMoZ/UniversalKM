# UniversalKM

Приложение для строки меню macOS: мышь и клавиатура Mac переходят на телефон или планшет (iOS, Android), когда курсор упирается в выбранный край экрана — как Universal Control, но для любого устройства. Телефон видит обычную Bluetooth‑клавиатуру и мышь; ею работает [ChameleonUltra](https://github.com/RfidResearchGroup/ChameleonUltra), подключённый к Mac по USB (macOS не даёт самому Mac быть Bluetooth‑клавиатурой).

> В разработке. План и требования — `openspec/changes/add-ble-hid-input-bridge/`.

## Требования

- macOS 14 или новее, Apple Silicon.
- ChameleonUltra с прошивкой UniversalKM (режим клавиатуры и мыши).
- Для сборки: Xcode 27 / Swift 6.

## Сборка

```bash
scripts/build-app.sh          # build/UniversalKM.app
scripts/build-app.sh --zip    # + build/UniversalKM-<версия>.zip
scripts/run.sh                # собрать, перезапустить и смотреть лог
```

Подпись: macOS привязывает разрешения «Универсальный доступ» и «Мониторинг ввода» к сертификату подписи. Скрипт берёт `SIGN_IDENTITY`, иначе первую идентичность «Apple Development», иначе самоподписанный сертификат проекта «UniversalKM Self-Signed» из связки ключей. С любым постоянным сертификатом разрешения переживают пересборки и обновления. Без сертификата сборка подписывается ad‑hoc, и разрешения сбрасываются каждый раз.

- **Сертификат проекта** лежит в связке ключей входа (ключ и сертификат «UniversalKM Self-Signed», 10 лет) и в секретах репозитория `SIGNING_CERTIFICATE_P12` / `SIGNING_CERTIFICATE_PASSWORD` — ими подписываются релизы. Резервная копия: «Связка ключей» → «Мои сертификаты» → «UniversalKM Self-Signed» → «Экспортировать…» (.p12 с паролем) — в менеджер паролей. Если сертификат потерять, следующее обновление один раз попросит разрешения заново.
- Самоподписанный сертификат не убирает предупреждение macOS при первом запуске (правый клик → «Открыть»); это делает только сертификат Apple Developer ID с нотаризацией.

## ChameleonUltra: прошивка с режимом клавиатуры и мыши

Bluetooth‑клавиатурой и мышью для телефона работает ChameleonUltra (USB `6868:8686`). В штатной прошивке такого режима нет: UniversalKM добавляет его патчами к прошивке [RfidResearchGroup/ChameleonUltra](https://github.com/RfidResearchGroup/ChameleonUltra) на зафиксированном коммите (`firmware/UPSTREAM`). Карты, слоты, кнопки и штатный клиент продолжают работать; режим клавиатуры и мыши включается только из приложения.

```bash
scripts/firmware-build.sh       # build/ultra-dfu-app.zip
scripts/firmware-flash.sh       # прошить по USB (штатный DFU)
```

- **Сборка.** Скрипт сам ставит Arm GNU Toolchain 12.2 и `nrfutil` в `~/Library/Caches/UniversalKM-firmware-tools`, скачивает прошивку апстрима в `build/firmware-src/`, кладёт туда `firmware/src/` и накладывает `firmware/patches/`. Docker не нужен. Готовый пакет есть и в каждом релизе: `chameleon-ultra-hid-dfu-app-<версия>.zip`.
- **Прошивка.** Закройте штатный клиент Chameleon и UniversalKM: порт может держать только одна программа. Скрипт сам переводит Chameleon в DFU. Если не вышло — выключите Chameleon, зажмите кнопку B и подключите USB (мигают светодиоды 4 и 5), скрипт подождёт. Обновляется только приложение прошивки, загрузчик не трогается, так что в DFU можно попасть всегда.
- **Откат на официальную прошивку:** `scripts/firmware-flash.sh --official` (версия по умолчанию — `OFFICIAL_TAG` в `firmware/UPSTREAM`) или `scripts/firmware-flash.sh --official v2.3.0`.

## Сопряжение с телефоном и планшетом

Пока UniversalKM запущен, Chameleon рекламирует себя как Bluetooth‑клавиатуру `ChameleonUltra`. Одновременно к нему подключаются до трёх устройств; отчёты получает то, на которое передан ввод.

- **Android:** Настройки → Bluetooth → «Добавить устройство» → `ChameleonUltra`. Указатель и клавиатура работают сразу.
- **iPhone / iPad:** Настройки → Bluetooth → `ChameleonUltra`. Клавиатура работает сразу. Курсор мыши iOS показывает только с AssistiveTouch (Универсальный доступ → Касание → AssistiveTouch); с iPhone курсор пока не двигается — известная проблема, задача 1.16.
- **PIN.** Если в настройках Chameleon включено сопряжение по PIN, телефон спросит его; если выключено (по умолчанию) — сопряжение без кода. Переключается штатным клиентом Chameleon: `hw settings blepair -e` / `-d`, PIN — `hw settings blekey`.
- **Не сопрягайте с Chameleon сам Mac** в настройках Bluetooth: Mac займёт одно из трёх соединений и станет получать нажатия («hello» напечатается на Mac). Если уже сопрягли — «Забыть это устройство».
- **Сопряжение запоминается:** после перезапуска приложения или Chameleon устройства подключаются сами. Удалить сопряжение: на телефоне «Забыть устройство», на Chameleon — штатным клиентом (`hw settings bleclearbonds`).
- **Когда приложение закрыто,** Chameleon отключает устройства и пропадает из поиска до следующего запуска — экранная клавиатура на телефоне возвращается.

## USB и Bluetooth между Mac и Chameleon

Приложение находит Chameleon по USB само и параллельно держит с ним Bluetooth‑соединение (штатный канал Nordic UART; это не сопряжение macOS). Если USB выдернуть, работа продолжается по Bluetooth, а когда USB вернётся — снова по USB. Пока Mac на связи по Bluetooth, он занимает одно из трёх соединений Chameleon, поэтому устройств остаётся два. Если Bluetooth‑связи с Mac нет и USB выдернули, Chameleon выключает режим клавиатуры и мыши, сам отпускает все клавиши и отключает устройства.

При первом запуске macOS спросит разрешение на Bluetooth — его нужно дать. Ключи `Resources/Info.plist`: `LSUIElement` (только строка меню), `NSBluetoothAlwaysUsageDescription` (Bluetooth‑канал к Chameleon), `SUFeedURL` и `SUPublicEDKey` (обновления).

## Демо‑режим `--ble-demo`

Проверка всей цепочки без перехвата ввода: каждое подключившееся устройство по очереди получает квадрат курсором, клик и текст `hello`, затем «всё отпущено».

```bash
scripts/run.sh --ble-demo       # собрать, запустить и смотреть лог
```

Откройте на устройствах заметки с курсором в тексте. Демо повторяется для устройства, когда оно переподключается (например, после выключения и включения Bluetooth).

## Обновления

Приложение само проверяет обновления раз в сутки, а кнопка «Обновления» в подвале панели проверяет сразу. Обновления устанавливает [Sparkle](https://sparkle-project.org): он берёт ленту `appcast.xml` из последнего релиза на GitHub и ставит только архивы, подписанные ключом проекта (EdDSA).

- **Ключ подписи.** Приватная половина лежит в связке ключей (учётная запись `UniversalKM`) и в секрете репозитория `SPARKLE_PRIVATE_KEY`; публичная — `SUPublicEDKey` в `Resources/Info.plist`. Если ключ потерять, уже установленные копии не смогут обновиться. Резервная копия — в менеджер паролей, затем удалить файл:
  ```bash
  .build/artifacts/sparkle/Sparkle/bin/generate_keys --account UniversalKM -x ~/universalkm-sparkle.key
  ```
- **Выпуск версии.** Поднять `CFBundleShortVersionString` и `CFBundleVersion` в `Resources/Info.plist`, написать `docs/releases/v<версия>.md`, влить в `main` и запушить тег:
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```
  Workflow `.github/workflows/release.yml` проверит, что тег совпадает с версией, прогонит тесты, соберёт архив приложения и прошивку Chameleon, подпишет ленту и опубликует релиз с `UniversalKM-<версия>.zip`, `appcast.xml` и `chameleon-ultra-hid-dfu-app-<версия>.zip`.
- **Локально без публикации:** `scripts/build-app.sh --zip && scripts/appcast.sh build/UniversalKM-<версия>.zip` — ключ берётся из связки ключей.

## Поддержать проект

UniversalKM бесплатный. Кнопка «♥ Поддержать» в подвале панели показывает способы поддержки. Они загружаются из [DeMoZ/donations](https://github.com/DeMoZ/donations) (`universalkm.json`), поэтому ссылки меняются без нового релиза.

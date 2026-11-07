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

Подпись: скрипт берёт первую идентичность «Apple Development» из связки ключей или ту, что задана в `SIGN_IDENTITY`. Без неё приложение подписывается ad‑hoc — тогда macOS забывает разрешения «Универсальный доступ» и «Мониторинг ввода» после каждой пересборки и каждого обновления.

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

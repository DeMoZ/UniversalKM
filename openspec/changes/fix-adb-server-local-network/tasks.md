# Tasks

## 1. Запуск сервера с отказом от ответственности

- [x] 1.1 `DisclaimedSpawn.swift` (`posix_spawn` + `responsibility_spawnattrs_setdisclaim` через `dlsym`, тайм‑аут) и `ADBClient.ensureServer` (design D1). Проверка: `swift build`; с пробником на C (тот же вызов) `adb start-server` вызывает запрос macOS «Локальная сеть» для `adb`, после разрешения сервер подключается к телефонам.
- [x] 1.2 `AndroidHIDTransport.startADB` и повторный запуск `track-devices` поднимают сервер через `ensureServer` (design D1). Проверка вручную на S10e и SM‑X115 по Wi‑Fi: сервер нет → приложение поднимает его, телефоны `device`; выход из приложения → `adb connect` из оболочки проходит через тот же сервер; повторный запуск → телефоны по Wi‑Fi; `adb kill-server` при работающем приложении → новый сервер, после выхода он тоже работает. Проверено 2026‑11‑09 (серверы pid 914, 1763).

## 2. Документация

- [x] 2.1 README.md и README.ru.md, раздел Android по Wi‑Fi: запрос macOS «Локальная сеть» для `adb`, где включить, если отказали, и что он повторится после обновления platform-tools. Проверка: строки есть в обоих файлах.

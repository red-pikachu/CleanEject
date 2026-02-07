# CleanEject v4.0

Нативное menu bar приложение для безопасного извлечения внешних дисков на macOS 26+ (Apple Silicon).

## Возможности

- **Автоочистка** — удаление системного мусора (`.DS_Store`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, `Thumbs.db`, `._*`) перед извлечением
- **Busy Detector** — определение процессов, блокирующих диск (`lsof`), с опциями повтора и принудительного извлечения
- **Space Analyzer** — фоновое сканирование ТОП-5 самых тяжёлых файлов на каждом диске с переходом в Finder
- **Статистика** — счётчик общего объёма очищенного мусора (сохраняется между запусками)
- **Liquid Glass UI** — нативный Glass-дизайн с `GlassEffectContainer` и `.glassEffect()` модификаторами
- **Звуковые эффекты** — системный звук "Glass" при успешном извлечении
- **Уведомления** — системные нотификации о результате извлечения
- **Автозапуск** — переключатель "Запуск при входе" через `SMAppService`

## Требования

- macOS 26.0+ (Tahoe)
- Apple Silicon (arm64)
- Xcode 26.2+

## Сборка

```bash
# Генерация Xcode-проекта (при изменении project.yml)
xcodegen generate

# Сборка Release
xcodebuild -project CleanEject.xcodeproj -scheme CleanEject \
  -configuration Release -arch arm64 build

# Установка
cp -R ~/Library/Developer/Xcode/DerivedData/CleanEject-*/Build/Products/Release/CleanEject.app /Applications/
```

Или открыть `CleanEject.xcodeproj` в Xcode и собрать через Product → Build.

## Структура проекта

```
CleanEjectSwift/
├── CleanEject/                  # Исходники
│   ├── CleanEjectApp.swift      # Весь код (@main, VolumeManager, UI, AppDelegate)
│   ├── Info.plist               # Конфигурация приложения (LSUIElement=true)
│   ├── CleanEject.entitlements  # Права (Hardened Runtime)
│   └── AppIcon.icns             # Иконка приложения
├── CleanEject.xcodeproj/        # Xcode-проект
├── project.yml                  # Спецификация xcodegen
└── README.md
```

## Техническая архитектура

- **Entry point**: `@main AppDelegate` с `static func main()` и `NSApplication.setActivationPolicy(.accessory)`
- **UI**: SwiftUI + AppKit (`NSPopover` для menu bar, `NSHostingController`)
- **State**: `@Observable VolumeManager` с `@State` в `MenuBarView`
- **Concurrency**: Swift 6 strict concurrency, `Task.detached` для фоновых операций, `@MainActor` изоляция
- **Notifications**: `NSWorkspace.shared.notificationCenter` — target-action паттерн для mount/unmount
- **Signing**: Ad-hoc (`-`), Hardened Runtime

## Версии

| Версия | Описание |
|--------|----------|
| 4.0    | Xcode-проект, @main, Hardened Runtime, оптимизированный refresh |
| 3.1    | Busy Detector, Async Deep Scan, Liquid Sounds |
| 3.0    | Space Analyzer, Custom Patterns, Stats |
| 2.0    | Liquid Glass UI, SwiftUI 7, @Observable |
| 1.0    | Базовая очистка и извлечение |

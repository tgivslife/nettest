# FFI Setup Guide

## Текущий статус

✅ Создана структура проекта:
- `src/lib.rs` - библиотечный крейт
- `Cargo.toml` настроен для сборки как `cdylib`
- Flutter проект создан в `flutter-ex/`

## Что сделано

1. **Rust библиотека:**
   - Функция `client_run` экспортирована через `pub use`
   - `Cargo.toml` настроен для сборки как библиотека (`cdylib`, `rlib`, `staticlib`)
   - Библиотека компилируется успешно

2. **Flutter проект:**
   - Базовый Flutter проект создан
   - Добавлена зависимость `ffi: ^2.1.0`
   - Заглушка для загрузки библиотеки

## Следующие шаги для полной интеграции

### 1. Собрать Rust библиотеку

```bash
cd /Users/oleksis/IdeaProjects/measurement-server-specure
cargo build --release
```

Библиотека будет в:
- Linux: `target/release/libnettest.so`
- macOS: `target/release/libnettest.dylib`
- Windows: `target/release/nettest.dll`

### 2. Создать FFI обертки в Rust

Нужно создать функции в `src/lib.rs`:

```rust
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[no_mangle]
pub extern "C" fn client_run_ffi(
    args_json: *const c_char,
    config_json: *const c_char,
) -> *mut c_char {
    // Парсим JSON
    // Запускаем async код в runtime
    // Возвращаем результат
}
```

### 3. Создать Dart FFI биндинги

В `flutter-ex/lib/ffi_bindings.dart`:

```dart
import 'dart:ffi';
import 'package:ffi/ffi.dart';

typedef ClientRunFFI = Pointer<Utf8> Function(
  Pointer<Utf8> argsJson,
  Pointer<Utf8> configJson,
);
```

### 4. Скопировать библиотеку в Flutter проект

Для каждой платформы нужно скопировать библиотеку в соответствующую папку.

## Проблемы для решения

1. **Async функции:** `client_run` - async, нужно запускать в tokio runtime
2. **Сериализация:** `FileConfig` не имеет Serialize, нужно добавить или использовать JSON вручную
3. **Параметры:** `Vec<String>` и `FileConfig` нужно передавать через JSON
4. **Результаты:** Нужно решить, как возвращать результаты (JSON, callback, stream)

## Рекомендации

Для полной интеграции лучше использовать **flutter_rust_bridge**, который:
- Автоматически генерирует биндинги
- Поддерживает async функции
- Автоматически сериализует типы
- Поддерживает Stream для обновлений в реальном времени


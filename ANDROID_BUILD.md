# Сборка для Android

## Предварительные требования

1. **Android NDK** - установите через Android Studio:
   - Tools → SDK Manager → SDK Tools → NDK
   - Или скачайте: https://developer.android.com/ndk/downloads

2. **cargo-ndk** - инструмент для сборки Rust под Android:
   ```bash
   cargo install cargo-ndk
   ```

3. **Переменная окружения** (опционально, если NDK не найден автоматически):
   ```bash
   export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/<version>
   # Или добавьте в ~/.zshrc
   ```

## Сборка

### 1. Соберите Rust библиотеки для всех архитектур:
```bash
./build_android_simple.sh
```

Это создаст библиотеки в:
- `flutter-ex/android/app/src/main/jniLibs/arm64-v8a/libnettest.so`
- `flutter-ex/android/app/src/main/jniLibs/armeabi-v7a/libnettest.so`
- `flutter-ex/android/app/src/main/jniLibs/x86_64/libnettest.so`
- `flutter-ex/android/app/src/main/jniLibs/x86/libnettest.so`

### 2. Соберите и запустите Flutter приложение:
```bash
cd flutter-ex
flutter build apk
# Или для запуска:
flutter run -d android
```

## Проверка

После сборки проверьте, что библиотеки на месте:
```bash
ls -lh flutter-ex/android/app/src/main/jniLibs/*/libnettest.so
```

## Примечания

- Flutter автоматически подхватывает библиотеки из `jniLibs/`
- Код загрузки уже есть в `lib/main.dart`: `DynamicLibrary.open('libnettest.so')`
- Для релизной сборки используйте: `flutter build apk --release`

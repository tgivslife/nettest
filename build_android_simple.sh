#!/bin/bash
set -e

echo "Сборка Rust библиотеки для Android..."

# Проверка наличия Android NDK
if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_NDK_ROOT" ]; then
    # Попробуем найти NDK автоматически
    if [ -d "$HOME/Library/Android/sdk/ndk" ]; then
        NDK_HOME=$(ls -d $HOME/Library/Android/sdk/ndk/* 2>/dev/null | head -1)
        if [ -n "$NDK_HOME" ]; then
            export ANDROID_NDK_HOME="$NDK_HOME"
            echo "✅ Найден NDK автоматически: $NDK_HOME"
        else
            echo "⚠️  NDK не найден"
            echo "Установите Android NDK через Android Studio:"
            echo "  Tools → SDK Manager → SDK Tools → NDK"
            exit 1
        fi
    else
        echo "⚠️  ANDROID_NDK_HOME не установлен и NDK не найден"
        echo "Установите Android NDK через Android Studio:"
        echo "  Tools → SDK Manager → SDK Tools → NDK"
        exit 1
    fi
else
    NDK_HOME=${ANDROID_NDK_HOME:-$ANDROID_NDK_ROOT}
fi

# Проверка структуры NDK (может быть в подпапке android-ndk-r*)
if [ -d "$NDK_HOME/android-ndk-r"* ]; then
    ACTUAL_NDK=$(ls -d "$NDK_HOME/android-ndk-r"* 2>/dev/null | head -1)
    if [ -n "$ACTUAL_NDK" ]; then
        NDK_HOME="$ACTUAL_NDK"
        echo "✅ Найден реальный NDK в подпапке: $NDK_HOME"
    fi
fi

export ANDROID_NDK_HOME="$NDK_HOME"
echo "Используется NDK: $NDK_HOME"

# Проверка что NDK существует
if [ ! -d "$NDK_HOME" ]; then
    echo "❌ NDK не найден по пути: $NDK_HOME"
    exit 1
fi

# Установка Android targets
echo "Проверка Android targets..."
rustup target add aarch64-linux-android || true
rustup target add armv7-linux-androideabi || true
rustup target add x86_64-linux-android || true
# i686-linux-android исключен - устаревшая архитектура, проблемы с атомарными операциями в OpenSSL

# Настройка переменных окружения для Android сборки
# Отключаем fontconfig (не нужен для Android, используется plotters)
export FONTCONFIG_NO_PKG_CONFIG=1
export RUST_FONTCONFIG_DLOPEN=1
export PKG_CONFIG_ALLOW_CROSS=1

# Установка cargo-ndk если нужно
if ! command -v cargo-ndk &> /dev/null; then
    echo "Установка cargo-ndk..."
    cargo install cargo-ndk
fi

# Создаем директорию для библиотек
mkdir -p flutter-ex/android/app/src/main/jniLibs

# Собираем для каждой архитектуры
# i686-linux-android исключен - устаревшая архитектура, проблемы с атомарными операциями в OpenSSL
ARCHS=(
    "aarch64-linux-android:arm64-v8a"
    "armv7-linux-androideabi:armeabi-v7a"
    "x86_64-linux-android:x86_64"
)

for arch_pair in "${ARCHS[@]}"; do
    IFS=':' read -r rust_target android_arch <<< "$arch_pair"
    echo ""
    echo "Сборка для $rust_target ($android_arch)..."
    
    if cargo ndk -t "$rust_target" build --release; then
        # Копируем библиотеку в правильную папку
        mkdir -p "flutter-ex/android/app/src/main/jniLibs/$android_arch"
        cp "target/$rust_target/release/libnettest.so" "flutter-ex/android/app/src/main/jniLibs/$android_arch/"
        echo "✅ Скопировано: libnettest.so -> jniLibs/$android_arch/"
    else
        echo "❌ Ошибка сборки для $rust_target"
        exit 1
    fi
done

echo ""
echo "✅ Все библиотеки собраны!"
echo ""
echo "Структура:"
ls -lh flutter-ex/android/app/src/main/jniLibs/*/libnettest.so 2>/dev/null || echo "Проверьте пути"
echo ""
echo "Следующие шаги:"
echo "1. Убедитесь, что библиотеки в: flutter-ex/android/app/src/main/jniLibs/"
echo "2. Запустите: cd flutter-ex && flutter build apk"
echo "3. Или: flutter run -d android"


#!/bin/bash
set -e

echo "Сборка Rust библиотеки для iOS..."

# Установка iOS target если нужно
echo "Проверка iOS target..."
rustup target add aarch64-apple-ios-sim || true

# Собираем для iOS (release)
# На Apple Silicon одна библиотека arm64 работает и для симулятора, и для устройства
echo "Сборка для iOS (aarch64-apple-ios-sim)..."
cargo build --release --target aarch64-apple-ios-sim

if [ $? -eq 0 ]; then
    echo "Сборка успешна!"
    
    # Создаем директорию Rust если её нет
    mkdir -p flutter-ex/ios/Rust
    
    # Копируем библиотеку
    cp target/aarch64-apple-ios-sim/release/libnettest.a flutter-ex/ios/Rust/libnettest.a
    
    echo "✅ Скопирована библиотека:"
    echo "   - libnettest.a (arm64) -> flutter-ex/ios/Rust/"
    echo ""
    echo "Проверка библиотеки:"
    lipo -info flutter-ex/ios/Rust/libnettest.a
    echo ""
    echo "✅ Готово! Библиотека автоматически слинкуется через .xcconfig файлы"
    echo "   (работает и для симулятора, и для устройства на Apple Silicon)"
else
    echo "❌ Ошибка сборки!"
    exit 1
fi


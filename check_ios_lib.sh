#!/bin/bash
echo "=== Проверка iOS библиотеки ==="
echo ""
echo "1. Проверка наличия библиотек:"
ls -lh target/aarch64-apple-ios/release/libnettest.a target/aarch64-apple-ios-sim/release/libnettest.a 2>/dev/null || echo "Библиотеки не найдены!"
echo ""
echo "2. Проверка символов в библиотеке для устройства:"
nm -g target/aarch64-apple-ios/release/libnettest.a 2>&1 | grep -E "(client_run_with_progress_ffi|client_run_ffi|get_progress_ffi|free_string)" | head -5
echo ""
echo "3. Проверка XCFramework:"
ls -la flutter-ex/ios/Frameworks/libnettest.xcframework/ 2>/dev/null || echo "XCFramework не найден!"
echo ""
echo "4. Проверка символов в XCFramework:"
nm -g flutter-ex/ios/Frameworks/libnettest.xcframework/ios-arm64/libnettest.framework/libnettest 2>&1 | grep -E "(client_run_with_progress_ffi|client_run_ffi)" | head -3
echo ""
echo "5. Размер библиотек:"
du -h target/aarch64-apple-ios/release/libnettest.a target/aarch64-apple-ios-sim/release/libnettest.a 2>/dev/null

#!/bin/bash
echo "=== Тест экспорта символов ==="
echo ""

echo "1. Проверка символов в статической библиотеке:"
nm -g flutter-ex/ios/Frameworks/libnettest.xcframework/ios-arm64-simulator/libnettest.framework/libnettest 2>&1 | grep -E "client_run_with_progress_ffi" | head -1

echo ""
echo "2. Проверка типа символа (T = экспортирован, t = локальный):"
nm flutter-ex/ios/Frameworks/libnettest.xcframework/ios-arm64-simulator/libnettest.framework/libnettest 2>&1 | grep "client_run_with_progress_ffi" | head -1

echo ""
echo "3. Проверка, что символы не скрыты:"
nm -gU flutter-ex/ios/Frameworks/libnettest.xcframework/ios-arm64-simulator/libnettest.framework/libnettest 2>&1 | grep "client_run_with_progress_ffi" | head -1

echo ""
echo "4. Проверка экспорта через objdump:"
objdump -T flutter-ex/ios/Frameworks/libnettest.xcframework/ios-arm64-simulator/libnettest.framework/libnettest 2>&1 | grep "client_run_with_progress_ffi" | head -1 || echo "objdump не поддерживает статические архивы"

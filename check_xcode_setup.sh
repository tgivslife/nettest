#!/bin/bash
echo "=== Проверка настройки Xcode проекта ==="
echo ""

echo "1. Проверка наличия framework:"
if [ -d "flutter-ex/ios/Frameworks/libnettest.xcframework" ]; then
    echo "✅ Framework найден: flutter-ex/ios/Frameworks/libnettest.xcframework"
else
    echo "❌ Framework НЕ найден!"
fi

echo ""
echo "2. Проверка символов в framework:"
nm -g flutter-ex/ios/Frameworks/libnettest.xcframework/ios-arm64/libnettest.framework/libnettest 2>&1 | grep -E "(client_run_with_progress_ffi|client_run_ffi)" | head -2
if [ $? -eq 0 ]; then
    echo "✅ Символы найдены в framework"
else
    echo "❌ Символы НЕ найдены!"
fi

echo ""
echo "3. Проверка настроек в project.pbxproj:"
echo "   Framework Search Paths:"
grep -A 1 "FRAMEWORK_SEARCH_PATHS" flutter-ex/ios/Runner.xcodeproj/project.pbxproj | grep "PROJECT_DIR" | head -1
echo ""
echo "   Other Linker Flags:"
grep -A 2 "OTHER_LDFLAGS" flutter-ex/ios/Runner.xcodeproj/project.pbxproj | grep "libnettest" | head -1
echo ""
echo "   Framework в Link Binary:"
grep "libnettest.xcframework in Frameworks" flutter-ex/ios/Runner.xcodeproj/project.pbxproj
if [ $? -eq 0 ]; then
    echo "✅ Framework добавлен в Link Binary"
else
    echo "❌ Framework НЕ добавлен в Link Binary!"
fi

echo ""
echo "4. Что проверить в Xcode:"
echo "   - General → Frameworks: libnettest.xcframework должен быть 'Do Not Embed'"
echo "   - Build Phases → Link Binary: libnettest.xcframework должен быть в списке"
echo "   - Build Settings → Framework Search Paths: \$(PROJECT_DIR)/Frameworks"
echo "   - Build Settings → Other Linker Flags: -framework libnettest"

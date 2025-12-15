# Library Setup for macOS

If you encounter "Library not loaded" error, follow these steps:

## 1. Build Library

```bash
cd /Users/oleksis/IdeaProjects/measurement-server-specure
cargo build --release
```

## 2. Copy Library

```bash
cd flutter-ex
mkdir -p macos/Runner/Frameworks
cp ../target/release/libnettest.dylib macos/Runner/Frameworks/
```

## 3. Fix Install Name (Important!)

```bash
cd flutter-ex
install_name_tool -id @rpath/libnettest.dylib macos/Runner/Frameworks/libnettest.dylib
```

This needs to be done every time after copying the library!

## 4. Check Dependencies

```bash
otool -L macos/Runner/Frameworks/libnettest.dylib
```

Should show `@rpath/libnettest.dylib` instead of absolute path.

## 5. Run Application

```bash
flutter run -d macos
```

## Alternative Method (for Development)

If problems persist, you can use absolute path:

1. Make sure the library exists:
   ```bash
   ls -la ../target/release/libnettest.dylib
   ```

2. The application will automatically try to load from absolute path as a last resort.

## Troubleshooting

- Check Flutter console - all loading attempts will be logged there
- Make sure entitlements files are updated (library loading permissions)
- Try `flutter clean` and rebuild the project

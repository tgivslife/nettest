# Flutter Example for Nettest

Integration of Rust nettest library with Flutter via FFI.

## Structure

- `lib/main.dart` - main Flutter UI
- `lib/ffi_bindings.dart` - FFI bindings for calling Rust functions
- `pubspec.yaml` - project dependencies

## Installation and Setup

### 1. Build Rust Library

```bash
cd /Users/oleksis/IdeaProjects/measurement-server-specure
cargo build --release
```

The library will be created in:
- **macOS**: `target/release/libnettest.dylib`
- **Linux**: `target/release/libnettest.so`
- **Windows**: `target/release/nettest.dll`

### 2. Copy Library to Flutter Project

#### For macOS:
```bash
cp ../target/release/libnettest.dylib libnettest.dylib
```

#### For Linux:
```bash
cp ../target/release/libnettest.so libnettest.so
```

### 3. Install Flutter Dependencies

```bash
cd flutter-ex
flutter pub get
```

### 4. Run Application

```bash
flutter run
```

## Usage

The application will automatically load the library on startup. Click the "Run Test" button to start a measurement.

### Example Code Usage

```dart
// Load library
final lib = DynamicLibrary.open('libnettest.dylib');
final nettestFFI = NettestFFI(lib);

// Run test with empty args (automatic server discovery)
final result = nettestFFI.runClient([]);

// Or with specific arguments
final result = nettestFFI.runClient([
  '-c',
  '--server', 'example.com',
  '--port', '5005'
]);
```

## FFI Functions

### `client_run_ffi`

```rust
pub extern "C" fn client_run_ffi(
    args_json: *const c_char,  // JSON array of strings
    config_json: *const c_char, // JSON config (optional)
) -> *mut c_char  // JSON result
```

**Parameters:**
- `args_json`: JSON string with array of arguments, e.g.: `["-c", "--server", "example.com"]`
- `config_json`: JSON string with configuration (can pass `null` for default values)

**Returns:**
- JSON string: `{"success": true}` or `{"error": "error message"}`

### `free_string`

Frees memory allocated by Rust for a string.

```rust
pub unsafe extern "C" fn free_string(ptr: *mut c_char)
```

## Notes

- Library must be compiled before running Flutter application
- On macOS and Linux, the library is searched in the current directory or in `../target/release/`
- For production, use `cargo build --release` for optimized version
- All errors are returned in JSON format

## Next Steps

- [ ] Add support for passing configuration via JSON
- [ ] Implement Stream for real-time updates
- [ ] Add measurement results handling
- [ ] Configure automatic builds for different platforms

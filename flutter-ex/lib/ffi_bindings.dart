import 'dart:ffi';
import 'dart:convert';
import 'package:ffi/ffi.dart';


/// FFI bindings for Rust nettest library
class NettestFFI {
  final DynamicLibrary lib;

  NettestFFI(this.lib);

  // Function signatures
  late final ClientRunFFI _clientRun = lib.lookupFunction<ClientRunFFINative, ClientRunFFI>(
    'client_run_ffi',
  );

  late final ClientRunWithProgressFFI _clientRunWithProgress = 
      lib.lookupFunction<ClientRunWithProgressFFINative, ClientRunWithProgressFFI>(
    'client_run_with_progress_ffi',
  );

  late final GetProgressFFI _getProgress = lib.lookupFunction<GetProgressFFINative, GetProgressFFI>(
    'get_progress_ffi',
  );

  late final FreeStringFFI _freeString = lib.lookupFunction<FreeStringFFINative, FreeStringFFI>(
    'free_string',
  );

  /// Run client measurement with progress support
  /// 
  /// [args] - List of command line arguments (e.g., ['-c', '--server', 'example.com'])
  /// [configJson] - Optional JSON config string (can be null for defaults)
  /// 
  /// Returns JSON string with result: {"success": true} or {"error": "error message"}
  /// 
  /// Use [getProgress] to poll for progress updates
  String? runClientWithProgress(
    List<String> args, {
    String? configJson,
  }) {
    try {
      // Convert args to JSON
      final argsJson = jsonEncode(args);
      final argsPtr = argsJson.toNativeUtf8();

      // Convert config to pointer (or null)
      Pointer<Utf8>? configPtr;
      if (configJson != null && configJson.isNotEmpty) {
        configPtr = configJson.toNativeUtf8();
      }

      // Call Rust function
      final resultPtr = _clientRunWithProgress(
        argsPtr,
        configPtr ?? nullptr,
      );

      if (resultPtr == nullptr) {
        malloc.free(argsPtr);
        if (configPtr != null && configPtr != nullptr) {
          malloc.free(configPtr.cast());
        }
        return null;
      }

      // Convert result to Dart string
      final result = resultPtr.toDartString();

      // Free Rust-allocated string
      _freeString(resultPtr);

      // Free Dart-allocated strings
      malloc.free(argsPtr);
      if (configPtr != null && configPtr != nullptr) {
        malloc.free(configPtr.cast());
      }

      return result;
    } catch (e) {
      return '{"error": "FFI call failed: $e"}';
    }
  }

  /// Get the latest progress update
  /// 
  /// Returns JSON string with MeasurementProgress or null if no progress available
  String? getProgress() {
    try {
      final progressPtr = _getProgress();
      if (progressPtr == nullptr) {
        return null;
      }

      final progressJson = progressPtr.toDartString();
      _freeString(progressPtr);
      return progressJson;
    } catch (e) {
      return null;
    }
  }

  /// Run client measurement
  /// 
  /// [args] - List of command line arguments (e.g., ['-c', '--server', 'example.com'])
  /// [configJson] - Optional JSON config string (can be null for defaults)
  /// 
  /// Returns JSON string with result: {"success": true} or {"error": "error message"}
  String? runClient(List<String> args, {String? configJson}) {
    try {
      // Convert args to JSON
      final argsJson = jsonEncode(args);
      final argsPtr = argsJson.toNativeUtf8();

      // Convert config to pointer (or null)
      Pointer<Utf8>? configPtr;
      if (configJson != null && configJson.isNotEmpty) {
        configPtr = configJson.toNativeUtf8();
      }

      // Call Rust function
      final resultPtr = _clientRun(
        argsPtr,
        configPtr ?? nullptr,
      );

      if (resultPtr == nullptr) {
        malloc.free(argsPtr);
        if (configPtr != null && configPtr != nullptr) {
          malloc.free(configPtr.cast());
        }
        return null;
      }

      // Convert result to Dart string
      final result = resultPtr.toDartString();

      // Free Rust-allocated string
      _freeString(resultPtr);

      // Free Dart-allocated strings
      malloc.free(argsPtr);
      if (configPtr != null && configPtr != nullptr) {
        malloc.free(configPtr.cast());
      }

      return result;
    } catch (e) {
      return '{"error": "FFI call failed: $e"}';
    }
  }
}

// Native function signatures
typedef ClientRunFFINative = Pointer<Utf8> Function(
  Pointer<Utf8> argsJson,
  Pointer<Utf8> configJson,
);

typedef ClientRunFFI = Pointer<Utf8> Function(
  Pointer<Utf8> argsJson,
  Pointer<Utf8> configJson,
);

typedef FreeStringFFINative = Void Function(
  Pointer<Utf8> ptr,
);

typedef FreeStringFFI = void Function(
  Pointer<Utf8> ptr,
);

// Progress callback function signatures
typedef ProgressCallbackNative = Void Function(
  Pointer<Utf8> progressJson,
);

typedef ProgressCallback = void Function(
  Pointer<Utf8> progressJson,
);

typedef ClientRunWithProgressFFINative = Pointer<Utf8> Function(
  Pointer<Utf8> argsJson,
  Pointer<Utf8> configJson,
);

typedef ClientRunWithProgressFFI = Pointer<Utf8> Function(
  Pointer<Utf8> argsJson,
  Pointer<Utf8> configJson,
);

typedef GetProgressFFINative = Pointer<Utf8> Function();

typedef GetProgressFFI = Pointer<Utf8> Function();



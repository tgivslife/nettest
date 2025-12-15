import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:ffi/ffi.dart';
import 'ffi_bindings.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nettest Flutter Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _status = 'Ready';
  bool _isLoading = false;
  NettestFFI? _nettestFFI;

  // Load the Rust library
  DynamicLibrary? _loadLibrary() {
    try {
      if (Platform.isAndroid) {
        return DynamicLibrary.open('libnettest.so');
      } else if (Platform.isIOS) {
        return DynamicLibrary.process();
      } else if (Platform.isLinux) {
        // Try to load from common locations
        final possiblePaths = [
          'libnettest.so',
          '../target/release/libnettest.so',
          '../../target/release/libnettest.so',
        ];
        for (final path in possiblePaths) {
          try {
            return DynamicLibrary.open(path);
          } catch (_) {
            continue;
          }
        }
        return null;
      } else if (Platform.isMacOS) {
        // Try to load from common locations (app bundle & local build tree)
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final possiblePaths = [
          // When running from build bundle: Runner.app/Contents/MacOS/Runner
          '$exeDir/../Frameworks/libnettest.dylib',
          '$exeDir/libnettest.dylib',
          // When running from project root
          'libnettest.dylib',
          '../libnettest.dylib',
          '../Frameworks/libnettest.dylib',
          '../target/release/libnettest.dylib',
          '../../target/release/libnettest.dylib',
          'macos/Runner/Frameworks/libnettest.dylib',
          // Absolute path as last resort
          '/Users/oleksis/IdeaProjects/measurement-server-specure/target/release/libnettest.dylib',
        ];
        String? lastError;
        for (final path in possiblePaths) {
          try {
            final lib = DynamicLibrary.open(path);
            print('Successfully loaded library from: $path');
            return lib;
          } catch (e) {
            lastError = 'Failed to load $path: $e';
            print(lastError);
            continue;
          }
        }
        print('All paths failed. Last error: $lastError');
        print('Executable dir: $exeDir');
        print('Current working directory: ${Directory.current.path}');
        return null;
      } else if (Platform.isWindows) {
        return DynamicLibrary.open('nettest.dll');
      }
    } catch (e) {
      print('Error loading library: $e');
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initializeLibrary();
  }

  void _initializeLibrary() {
    final lib = _loadLibrary();
    if (lib != null) {
      setState(() {
        _nettestFFI = NettestFFI(lib);
        _status = 'Library loaded successfully';
      });
    } else {
      setState(() {
        _status = 'Error: Could not load library.\n'
            'Tried multiple paths. Check console for details.\n'
            'Make sure library is at: macos/Runner/Frameworks/libnettest.dylib';
      });
    }
  }

  Future<void> _runTest() async {
    if (_nettestFFI == null) {
      setState(() {
        _status = 'Error: Library not loaded';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _status = 'Running test...';
    });

    try {
      // Example: run client with minimal args
      // This will automatically find nearest server
      final args = <String>[]; // Empty args = auto-find server
      
      final result = _nettestFFI!.runClient(args);
      
      if (result != null) {
        final resultJson = jsonDecode(result) as Map<String, dynamic>;
        
        if (resultJson.containsKey('success')) {
          setState(() {
            _status = 'Test completed successfully!';
            _isLoading = false;
          });
        } else if (resultJson.containsKey('error')) {
          setState(() {
            _status = 'Error: ${resultJson['error']}';
            _isLoading = false;
          });
        }
      } else {
        setState(() {
          _status = 'Error: No result returned';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Nettest Flutter Example'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text(
              'Nettest Flutter Integration',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Text(
              'Status: $_status',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _isLoading ? null : _runTest,
              child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text('Run Test'),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


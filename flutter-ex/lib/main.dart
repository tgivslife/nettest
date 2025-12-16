import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
// import 'package:flutter/foundation.dart'; // Not used
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
  String _currentPhase = '';
  double _progress = 0.0;
  double? _pingMedian;
  double? _downloadSpeed;
  double? _uploadSpeed;
  List<Map<String, dynamic>> _threads = []; // Thread information during test
  List<Map<String, dynamic>> _threadResults = []; // Detailed thread results after completion

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

  StreamSubscription? _progressSubscription;

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
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
      _progress = 0.0;
      _currentPhase = '';
      _pingMedian = null;
      _downloadSpeed = null;
      _uploadSpeed = null;
      _threads = [];
      _threadResults = [];
    });

    // Start polling for progress updates every second
    _progressSubscription?.cancel();
    _progressSubscription = Stream.periodic(const Duration(milliseconds: 500), (i) => i)
        .listen((_) {
      if (_nettestFFI == null || !_isLoading) return;
      
      final progressJson = _nettestFFI!.getProgress();
      if (progressJson != null) {
        try {
          final progress = jsonDecode(progressJson) as Map<String, dynamic>;
          print('Progress update: phase=${progress['phase']}, percent=${progress['progress_percent']}'); // Debug log
          
          // Use SchedulerBinding to ensure UI updates on the correct frame
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _currentPhase = progress['phase'] as String? ?? '';
                _progress = (progress['progress_percent'] as num?)?.toDouble() ?? 0.0;
                _pingMedian = (progress['ping_median_ms'] as num?)?.toDouble();
                _downloadSpeed = (progress['download_speed_mbps'] as num?)?.toDouble();
                _uploadSpeed = (progress['upload_speed_mbps'] as num?)?.toDouble();
                
                // Update thread information
                if (progress['threads'] != null) {
                  _threads = List<Map<String, dynamic>>.from(
                    (progress['threads'] as List).map((t) => t as Map<String, dynamic>)
                  );
                }
                
                // Update thread results (available after completion)
                if (progress['thread_results'] != null) {
                  _threadResults = List<Map<String, dynamic>>.from(
                    (progress['thread_results'] as List).map((t) => t as Map<String, dynamic>)
                  );
                }
                
                // Update status with current phase
                final phaseNames = {
                  'starting': 'Starting...',
                  'greeting': 'Connecting...',
                  'init_download': 'Initializing download...',
                  'ping': 'Measuring ping...',
                  'download': 'Testing download speed...',
                  'upload': 'Testing upload speed...',
                  'signed_result': 'Saving results...',
                  'completed': 'Test completed',
                };
                
                _status = phaseNames[_currentPhase] ?? 'Running test...';
                
                if (_pingMedian != null) {
                  _status += '\nPing: ${_pingMedian!.toStringAsFixed(2)} ms';
                }
                if (_downloadSpeed != null) {
                  _status += '\nDownload: ${_downloadSpeed!.toStringAsFixed(2)} Mbps';
                }
                if (_uploadSpeed != null) {
                  _status += '\nUpload: ${_uploadSpeed!.toStringAsFixed(2)} Mbps';
                }
                
                // Check for completion
                if (_currentPhase == 'completed' || _currentPhase == 'error') {
                  _isLoading = false;
                  _progressSubscription?.cancel();
                  _progressSubscription = null;
                  
                  if (_currentPhase == 'completed') {
                    _status = 'Test completed successfully!';
                    _progress = 100.0;
                    
                    // Store final thread results
                    if (progress['thread_results'] != null) {
                      _threadResults = List<Map<String, dynamic>>.from(
                        (progress['thread_results'] as List).map((t) => t as Map<String, dynamic>)
                      );
                      print('Stored ${_threadResults.length} thread results'); // Debug
                    }
                  } else {
                    _status = 'Test failed';
                  }
                } else {
                  // Also update thread_results during progress if available
                  if (progress['thread_results'] != null && (progress['thread_results'] as List).isNotEmpty) {
                    _threadResults = List<Map<String, dynamic>>.from(
                      (progress['thread_results'] as List).map((t) => t as Map<String, dynamic>)
                    );
                  }
                }
              });
            }
          });
        } catch (e) {
          print('Error parsing progress: $e');
        }
      } else {
        print('No progress available yet'); // Debug log
      }
    });

    // Give UI a moment to start polling and render
    await Future.delayed(const Duration(milliseconds: 200));
    
    // Force a frame update to show initial state
    if (mounted) {
      setState(() {
        _status = 'Starting test...';
        _progress = 0.0;
      });
    }

    // Example: run client with minimal args
    // This will automatically find nearest server
    final args = <String>[]; // Empty args = auto-find server
    
    // Run test - now it returns immediately and runs in background
    print('Starting test...'); // Debug log
    
    final result = _nettestFFI!.runClientWithProgress(args);
    
    if (result != null) {
      final resultJson = jsonDecode(result) as Map<String, dynamic>;
      if (resultJson.containsKey('error')) {
        // Test failed to start
        setState(() {
          _isLoading = false;
          _status = 'Error: ${resultJson['error']}';
        });
        _progressSubscription?.cancel();
        _progressSubscription = null;
        return;
      }
    }
    
    // Test started successfully in background
    // Polling will handle progress updates and completion check
    // The main progress polling will also check for completion
    
    // Don't wait for test to complete - let polling handle updates
    // UI will update via polling every 500ms
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Nettest Flutter Example'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const Text(
              'Nettest Flutter Integration',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            if (_isLoading || _progress > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40.0),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _progress > 0 ? _progress / 100.0 : null,
                      minHeight: 10,
                      backgroundColor: Colors.grey[300],
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _progress > 0 ? '${_progress.toStringAsFixed(1)}%' : 'Starting...',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            if (_currentPhase.isNotEmpty || _isLoading)
              Text(
                _currentPhase.isNotEmpty ? 'Phase: $_currentPhase' : 'Initializing...',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            const SizedBox(height: 10),
            if (_pingMedian != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Text(
                  'Ping: ${_pingMedian!.toStringAsFixed(2)} ms',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            if (_downloadSpeed != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Text(
                  'Download: ${_downloadSpeed!.toStringAsFixed(2)} Mbps',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            if (_uploadSpeed != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Text(
                  'Upload: ${_uploadSpeed!.toStringAsFixed(2)} Mbps',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            const SizedBox(height: 20),
            Text(
              'Status: $_status',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            if (_threads.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text(
                'Threads:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ...(_threads.map((thread) {
                final threadId = thread['thread_id'] as int? ?? 0;
                final phase = thread['phase'] as String? ?? 'unknown';
                final bytesReceived = thread['bytes_received'] as int? ?? 0;
                final bytesSent = thread['bytes_sent'] as int? ?? 0;
                final failed = thread['failed'] as bool? ?? false;
                // Parse measurements from JSON (they come as arrays of [time_ns, bytes])
                final downloadMeasurementsRaw = thread['download_measurements'] as List? ?? [];
                final uploadMeasurementsRaw = thread['upload_measurements'] as List? ?? [];
                
                // Convert to List of tuples for easier access
                final downloadMeasurements = downloadMeasurementsRaw.map((m) {
                  if (m is List && m.length >= 2) {
                    return [m[0] as int? ?? 0, m[1] as int? ?? 0];
                  }
                  return [0, 0];
                }).toList();
                
                final uploadMeasurements = uploadMeasurementsRaw.map((m) {
                  if (m is List && m.length >= 2) {
                    return [m[0] as int? ?? 0, m[1] as int? ?? 0];
                  }
                  return [0, 0];
                }).toList();
                
                // Calculate statistics
                final downloadSampleCount = downloadMeasurements.length;
                final uploadSampleCount = uploadMeasurements.length;
                final lastDownloadBytes = downloadMeasurements.isNotEmpty 
                    ? (downloadMeasurements.last as List)[1] as int? ?? 0 
                    : 0;
                final lastUploadBytes = uploadMeasurements.isNotEmpty 
                    ? (uploadMeasurements.last as List)[1] as int? ?? 0 
                    : 0;
                
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 20.0),
                  child: Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      color: failed ? Colors.red[50] : Colors.grey[100],
                      borderRadius: BorderRadius.circular(8.0),
                      border: Border.all(
                        color: failed ? Colors.red : Colors.grey[300]!,
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Thread $threadId',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: failed ? Colors.red : Colors.black,
                              ),
                            ),
                            Text(
                              phase,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[700],
                              ),
                            ),
                            Text(
                              '↓${(bytesReceived / 1024 / 1024).toStringAsFixed(1)}MB ↑${(bytesSent / 1024 / 1024).toStringAsFixed(1)}MB',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                        // Detailed state information from last poll
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8.0),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4.0),
                            border: Border.all(color: Colors.grey[300]!, width: 1),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.info_outline, size: 12, color: Colors.grey[600]),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Last State Poll:',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey[700],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              if (downloadSampleCount > 0) ...[
                                Row(
                                  children: [
                                    const Icon(Icons.download, size: 12, color: Colors.blue),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        'Download: $downloadSampleCount samples, ${(bytesReceived / 1024 / 1024).toStringAsFixed(2)} MB total',
                                        style: TextStyle(fontSize: 10, color: Colors.grey[700]),
                                      ),
                                    ),
                                  ],
                                ),
                                if (lastDownloadBytes > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 16, top: 2),
                                    child: Text(
                                      'Last chunk: ${(lastDownloadBytes / 1024).toStringAsFixed(1)} KB',
                                      style: TextStyle(fontSize: 9, color: Colors.grey[500], fontStyle: FontStyle.italic),
                                    ),
                                  ),
                              ] else
                                Text(
                                  'Download: No samples yet',
                                  style: TextStyle(fontSize: 10, color: Colors.grey[500], fontStyle: FontStyle.italic),
                                ),
                              if (uploadSampleCount > 0) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.upload, size: 12, color: Colors.green),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        'Upload: $uploadSampleCount samples, ${(bytesSent / 1024 / 1024).toStringAsFixed(2)} MB total',
                                        style: TextStyle(fontSize: 10, color: Colors.grey[700]),
                                      ),
                                    ),
                                  ],
                                ),
                                if (lastUploadBytes > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 16, top: 2),
                                    child: Text(
                                      'Last chunk: ${(lastUploadBytes / 1024).toStringAsFixed(1)} KB',
                                      style: TextStyle(fontSize: 9, color: Colors.grey[500], fontStyle: FontStyle.italic),
                                    ),
                                  ),
                              ] else
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Upload: No samples yet',
                                    style: TextStyle(fontSize: 10, color: Colors.grey[500], fontStyle: FontStyle.italic),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList()),
            ],
            // Show detailed results after completion
            if (_threadResults.isNotEmpty && !_isLoading) ...[
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 10),
              const Text(
                'Detailed Thread Results:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              ...(_threadResults.map((result) {
                final threadId = result['thread_id'] as int? ?? 0;
                final failed = result['failed'] as bool? ?? false;
                final totalBytesReceived = result['total_download_bytes'] as int? ?? 0;
                final totalBytesSent = result['total_upload_bytes'] as int? ?? 0;
                final downloadSamples = result['download_samples'] as int? ?? 0;
                final uploadSamples = result['upload_samples'] as int? ?? 0;
                final downloadMeasurements = result['download_measurements'] as List? ?? [];
                final uploadMeasurements = result['upload_measurements'] as List? ?? [];
                final envelope = result['envelope'] as String?;
                
                // Calculate average speeds from measurements
                double? avgDownloadSpeed;
                double? avgUploadSpeed;
                double? maxDownloadSpeed;
                double? maxUploadSpeed;
                
                if (downloadMeasurements.isNotEmpty && downloadMeasurements.length > 1) {
                  // Calculate average speed from first to last measurement
                  final firstTime = (downloadMeasurements.first as List)[0] as int? ?? 0;
                  final lastTime = (downloadMeasurements.last as List)[0] as int? ?? 0;
                  final durationNs = lastTime - firstTime;
                  
                  if (durationNs > 0) {
                    avgDownloadSpeed = (totalBytesReceived * 8.0 * 1000000000) / (durationNs * 1000000); // Mbps
                  }
                  
                  // Calculate max speed from individual chunks
                  double maxSpeed = 0.0;
                  for (int i = 1; i < downloadMeasurements.length; i++) {
                    final prevTime = (downloadMeasurements[i - 1] as List)[0] as int? ?? 0;
                    final currTime = (downloadMeasurements[i] as List)[0] as int? ?? 0;
                    final prevBytes = (downloadMeasurements[i - 1] as List)[1] as int? ?? 0;
                    final currBytes = (downloadMeasurements[i] as List)[1] as int? ?? 0;
                    final chunkBytes = currBytes - prevBytes;
                    final chunkTime = currTime - prevTime;
                    
                    if (chunkTime > 0) {
                      final speed = (chunkBytes * 8.0 * 1000000000) / (chunkTime * 1000000);
                      if (speed > maxSpeed) maxSpeed = speed;
                    }
                  }
                  maxDownloadSpeed = maxSpeed > 0 ? maxSpeed : null;
                }
                
                if (uploadMeasurements.isNotEmpty && uploadMeasurements.length > 1) {
                  // Calculate average speed from first to last measurement
                  final firstTime = (uploadMeasurements.first as List)[0] as int? ?? 0;
                  final lastTime = (uploadMeasurements.last as List)[0] as int? ?? 0;
                  final durationNs = lastTime - firstTime;
                  
                  if (durationNs > 0) {
                    avgUploadSpeed = (totalBytesSent * 8.0 * 1000000000) / (durationNs * 1000000); // Mbps
                  }
                  
                  // Calculate max speed from individual chunks
                  double maxSpeed = 0.0;
                  for (int i = 1; i < uploadMeasurements.length; i++) {
                    final prevTime = (uploadMeasurements[i - 1] as List)[0] as int? ?? 0;
                    final currTime = (uploadMeasurements[i] as List)[0] as int? ?? 0;
                    final prevBytes = (uploadMeasurements[i - 1] as List)[1] as int? ?? 0;
                    final currBytes = (uploadMeasurements[i] as List)[1] as int? ?? 0;
                    final chunkBytes = currBytes - prevBytes;
                    final chunkTime = currTime - prevTime;
                    
                    if (chunkTime > 0) {
                      final speed = (chunkBytes * 8.0 * 1000000000) / (chunkTime * 1000000);
                      if (speed > maxSpeed) maxSpeed = speed;
                    }
                  }
                  maxUploadSpeed = maxSpeed > 0 ? maxSpeed : null;
                }
                
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 20.0),
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12.0),
                    side: BorderSide(
                      color: failed ? Colors.red : Colors.green,
                      width: 2,
                    ),
                  ),
                  color: failed ? Colors.red[50] : Colors.green[50],
                  child: ExpansionTile(
                    leading: Icon(
                      failed ? Icons.error : Icons.check_circle,
                      color: failed ? Colors.red : Colors.green,
                      size: 28,
                    ),
                    title: Text(
                      'Thread $threadId: ${failed ? "Failed" : "Success"}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: failed ? Colors.red[800] : Colors.green[800],
                      ),
                    ),
                    subtitle: Text(
                      '${downloadSamples} download samples, ${uploadSamples} upload samples',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    trailing: envelope != null
                        ? const Icon(Icons.verified, color: Colors.green, size: 20)
                        : null,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Download section
                            Container(
                              padding: const EdgeInsets.all(12.0),
                              decoration: BoxDecoration(
                                color: Colors.blue[50],
                                borderRadius: BorderRadius.circular(8.0),
                                border: Border.all(color: Colors.blue[200]!, width: 1),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.download, color: Colors.blue, size: 20),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Download Statistics',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.blue[900],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  _buildStatRow('Total Data', '${(totalBytesReceived / 1024 / 1024).toStringAsFixed(2)} MB'),
                                  _buildStatRow('Samples', '$downloadSamples'),
                                  if (avgDownloadSpeed != null)
                                    _buildStatRow('Average Speed', '${avgDownloadSpeed.toStringAsFixed(2)} Mbps'),
                                  if (maxDownloadSpeed != null)
                                    _buildStatRow('Peak Speed', '${maxDownloadSpeed.toStringAsFixed(2)} Mbps', isHighlight: true),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Upload section
                            Container(
                              padding: const EdgeInsets.all(12.0),
                              decoration: BoxDecoration(
                                color: Colors.orange[50],
                                borderRadius: BorderRadius.circular(8.0),
                                border: Border.all(color: Colors.orange[200]!, width: 1),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.upload, color: Colors.orange, size: 20),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Upload Statistics',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.orange[900],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  _buildStatRow('Total Data', '${(totalBytesSent / 1024 / 1024).toStringAsFixed(2)} MB'),
                                  _buildStatRow('Samples', '$uploadSamples'),
                                  if (avgUploadSpeed != null)
                                    _buildStatRow('Average Speed', '${avgUploadSpeed.toStringAsFixed(2)} Mbps'),
                                  if (maxUploadSpeed != null)
                                    _buildStatRow('Peak Speed', '${maxUploadSpeed.toStringAsFixed(2)} Mbps', isHighlight: true),
                                ],
                              ),
                            ),
                            if (envelope != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12.0),
                                decoration: BoxDecoration(
                                  color: Colors.green[50],
                                  borderRadius: BorderRadius.circular(8.0),
                                  border: Border.all(color: Colors.green[200]!, width: 1),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.verified, color: Colors.green, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Signed Result Available',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.green[800],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList()),
            ],
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isLoading ? null : _runTest,
              child: _isLoading
                  ? const CircularProgressIndicator()
                  : const Text('Run Test'),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildStatRow(String label, String value, {bool isHighlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[700],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isHighlight ? FontWeight.bold : FontWeight.normal,
              color: isHighlight ? Colors.blue[900] : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}


#!/bin/bash
set -eo pipefail

trap 'echo "❌ GAGAL pada baris $LINENO (exit code: $?)"' ERR

echo "=== 0. Sinkronisasi Otomatis Seluruh File Dart CineLens iOS ==="
rm -rf lib/features
mkdir -p lib/features/about/presentation/screens
mkdir -p lib/features/cinema_camera/domain/entities
mkdir -p lib/features/cinema_camera/data/datasources
mkdir -p lib/features/cinema_camera/presentation/providers
mkdir -p lib/features/cinema_camera/presentation/screens

cat << 'DART_FILE_EOF' > lib/main.dart
// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/cinema_camera/presentation/screens/camera_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ProviderScope(child: CineLensApp()));
}

class CineLensApp extends StatelessWidget {
  const CineLensApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CineLens iOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          brightness: Brightness.dark,
        ),
      ),
      home: const CameraScreen(),
    );
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/about/presentation/screens/about_screen.dart
// lib/features/about/presentation/screens/about_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String developerName = 'Wisnu Sastra Wijaya';
  static const String supportEmail = 'wisnusastra9@gmail.com';
  static const String appVersion = '1.1.0 ProRes';
  static const MethodChannel _channel =
      MethodChannel('com.cinelens.ios/native_camera');

  void _copyEmail(BuildContext context) {
    Clipboard.setData(const ClipboardData(text: supportEmail));
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Email $supportEmail berhasil disalin'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _sendFeedback() async {
    await _channel.invokeMethod<bool>('shareText', {
      'text': 'Halo $developerName,\n\n'
          'Saya ingin memberikan masukan / dukungan untuk aplikasi CineLens iOS:\n\n'
          '(Tulis pesan Anda di sini)\n\n'
          'Kirim ke: $supportEmail',
      'subject': 'CineLens iOS - Support & Masukan',
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E10),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('About CineLens'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.amberAccent, width: 1.5),
                    ),
                    child: const Icon(
                      Icons.camera_rounded,
                      color: Colors.amberAccent,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'CineLens iOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Native AVFoundation ProRes & Full-Sensor Cinema Camera',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Version $appVersion',
                      style: TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'DEVELOPER',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.amber.withValues(alpha: 0.2),
                        child: const Text(
                          'WS',
                          style: TextStyle(
                            color: Colors.amberAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              developerName,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Lead iOS & Flutter Developer',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SUPPORT & MASUKAN',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Punya ide fitur baru, laporan bug, atau ingin memberikan dukungan untuk pengembangan CineLens? Hubungi developer langsung melalui email di bawah ini:',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232329),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.email_outlined,
                          color: Colors.amberAccent,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: SelectableText(
                            supportEmail,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Salin Email',
                          onPressed: () => _copyEmail(context),
                          icon: const Icon(
                            Icons.copy_rounded,
                            color: Colors.white70,
                            size: 19,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => _copyEmail(context),
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          label: const Text('Salin Email'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _sendFeedback,
                          icon: const Icon(Icons.send_rounded, size: 18),
                          label: const Text(
                            'Kirim Masukan',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/domain/entities/cinema_camera_enums.dart
// lib/features/cinema_camera/domain/entities/cinema_camera_enums.dart

enum ProResCodec {
  proRes422('prores422', 'PRORES 422'),
  proRes422HQ('prores422hq', 'PRORES 422 HQ'),
  proRes422LT('prores422lt', 'PRORES 422 LT'),
  proRes422Proxy('prores422proxy', 'PRORES PROXY'),
  hevc('hevc', 'HEVC 10-BIT');

  final String nativeKey;
  final String label;
  const ProResCodec(this.nativeKey, this.label);
}

enum IPhoneLens {
  ultraWide('ultrawide', '0.5x'),
  wide('wide', '1x'),
  telephoto('telephoto', '3x'),
  front('front', 'FRONT');

  final String nativeKey;
  final String label;
  const IPhoneLens(this.nativeKey, this.label);
}

enum CinemaAspectRatio {
  scope239('2.39:1 SCOPE', 2.39),
  widescreen16x9('16:9 WIDESCREEN', 16 / 9),
  classic4x3('4:3 SENSOR', 4 / 3),
  full('FULL SENSOR', null);

  final String label;
  final double? ratio;
  const CinemaAspectRatio(this.label, this.ratio);
}

enum GridOverlayType {
  ruleOfThirds('Rule of Thirds'),
  goldenRatio('Golden Ratio'),
  crosshair('Crosshair'),
  none('Off');

  final String label;
  const GridOverlayType(this.label);
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/domain/entities/cinema_tone.dart
// lib/features/cinema_camera/domain/entities/cinema_tone.dart

class CinemaTone {
  final String id;
  final String name;
  final String subtitle;
  final List<double> matrix;

  const CinemaTone({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.matrix,
  });

  static const List<double> identityMatrix = <double>[
    1.0, 0.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 1.0, 0.0,
  ];

  List<double> scaledMatrix(double intensity) {
    final t = intensity.clamp(0.0, 1.0);
    if (t >= 0.999) return matrix;
    if (t <= 0.001) return identityMatrix;
    return List<double>.generate(20, (i) {
      return identityMatrix[i] + (matrix[i] - identityMatrix[i]) * t;
    });
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/data/datasources/cinema_tones_preset_source.dart
// lib/features/cinema_camera/data/datasources/cinema_tones_preset_source.dart

import '../../domain/entities/cinema_tone.dart';

class CinemaTonesPresetSource {
  const CinemaTonesPresetSource();

  List<CinemaTone> getPresets() {
    return const [
      CinemaTone(
        id: 'rec709_raw',
        name: 'REC.709 RAW',
        subtitle: 'Natural Sensor',
        matrix: CinemaTone.identityMatrix,
      ),
      CinemaTone(
        id: 'teal_orange',
        name: 'TEAL & ORANGE',
        subtitle: 'Blockbuster Action',
        matrix: <double>[
          1.18, 0.05, -0.08, 0.0, 8.0,
          -0.02, 1.02, 0.06, 0.0, 0.0,
          -0.06, 0.12, 1.10, 0.0, 6.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'vision3_500t',
        name: 'VISION3 500T',
        subtitle: '35mm Tungsten Film',
        matrix: <double>[
          0.96, 0.02, 0.06, 0.0, -2.0,
          0.01, 1.03, 0.04, 0.0, 2.0,
          0.04, 0.08, 1.16, 0.0, 8.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'kodak_2383',
        name: 'KODAK 2383',
        subtitle: 'Print Film Contrast',
        matrix: <double>[
          1.12, 0.04, -0.02, 0.0, 6.0,
          0.02, 1.06, 0.01, 0.0, 2.0,
          -0.04, 0.03, 0.94, 0.0, -4.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'fuji_velvia',
        name: 'FUJI VELVIA',
        subtitle: 'Vivid Cinema Slide',
        matrix: <double>[
          1.20, -0.05, -0.03, 0.0, -4.0,
          -0.03, 1.18, -0.03, 0.0, -4.0,
          -0.02, -0.04, 1.22, 0.0, -2.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'noir_bw',
        name: 'NOIR B&W',
        subtitle: 'Monochrome 35mm',
        matrix: <double>[
          0.33, 0.59, 0.11, 0.0, -8.0,
          0.33, 0.59, 0.11, 0.0, -8.0,
          0.33, 0.59, 0.11, 0.0, -8.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
    ];
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/data/datasources/native_cinema_camera_datasource.dart
// lib/features/cinema_camera/data/datasources/native_cinema_camera_datasource.dart

import 'package:flutter/services.dart';

class NativeCameraInitResult {
  final int textureId;
  final bool supportsProRes;
  final String sensorResolution;

  const NativeCameraInitResult({
    required this.textureId,
    required this.supportsProRes,
    required this.sensorResolution,
  });
}

class NativeCinemaCameraDataSource {
  static const MethodChannel _channel =
      MethodChannel('com.cinelens.ios/native_camera');

  Future<NativeCameraInitResult> initialize({
    required String lens,
    required int fps,
  }) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'initialize',
      {'lens': lens, 'fps': fps},
    );
    return NativeCameraInitResult(
      textureId: (res?['textureId'] as num?)?.toInt() ?? -1,
      supportsProRes: (res?['supportsProRes'] as bool?) ?? false,
      sensorResolution: (res?['sensorResolution'] as String?) ?? '12MP',
    );
  }

  Future<NativeCameraInitResult> switchLens({
    required String lens,
    required int fps,
  }) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'switchLens',
      {'lens': lens, 'fps': fps},
    );
    return NativeCameraInitResult(
      textureId: (res?['textureId'] as num?)?.toInt() ?? -1,
      supportsProRes: (res?['supportsProRes'] as bool?) ?? false,
      sensorResolution: (res?['sensorResolution'] as String?) ?? '12MP',
    );
  }

  Future<void> setFps(int fps) async {
    await _channel.invokeMethod<bool>('setFps', {'fps': fps});
  }

  Future<void> setExposureBias(double ev) async {
    await _channel.invokeMethod<bool>('setExposureBias', {'ev': ev});
  }

  Future<void> setFocusAndExposurePoint(double x, double y) async {
    await _channel.invokeMethod<bool>(
      'setFocusAndExposurePoint',
      {'x': x, 'y': y},
    );
  }

  Future<void> setFlashMode(String mode) async {
    await _channel.invokeMethod<bool>('setFlashMode', {'mode': mode});
  }

  Future<void> capturePhoto({
    required List<double> matrix,
    required String flashMode,
  }) async {
    await _channel.invokeMapMethod<String, dynamic>('capturePhoto', {
      'matrix': matrix,
      'flashMode': flashMode,
    });
  }

  Future> startRecording({
    required String codec,
    required int fps,
  }) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'startRecording',
      {'codec': codec, 'fps': fps},
    );
    return res ?? const {};
  }

  Future> stopRecording() async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'stopRecording',
    );
    return res ?? const {};
  }

  Future<void> dispose() async {
    await _channel.invokeMethod<bool>('dispose');
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/presentation/providers/cinema_camera_provider.dart
// lib/features/cinema_camera/presentation/providers/cinema_camera_provider.dart

import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/cinema_tones_preset_source.dart';
import '../../data/datasources/native_cinema_camera_datasource.dart';
import '../../domain/entities/cinema_camera_enums.dart';
import '../../domain/entities/cinema_tone.dart';

class CinemaCameraState {
  final int textureId;
  final bool isInitializing;
  final bool supportsProRes;
  final String sensorResolution;
  final List<CinemaTone> presets;
  final int selectedToneIndex;
  final double lutIntensity;
  final double exposureBias;
  final IPhoneLens selectedLens;
  final ProResCodec selectedCodec;
  final CinemaAspectRatio aspectRatio;
  final GridOverlayType gridType;
  final bool isVideoMode;
  final int targetFps;
  final bool isRecording;
  final bool isBusy;
  final int recordingSeconds;
  final bool isFlashOn;
  final String? errorBanner;
  final String? toastMessage;
  final int toastNonce;

  const CinemaCameraState({
    this.textureId = -1,
    this.isInitializing = true,
    this.supportsProRes = false,
    this.sensorResolution = '12MP',
    required this.presets,
    this.selectedToneIndex = 1,
    this.lutIntensity = 1.0,
    this.exposureBias = 0.0,
    this.selectedLens = IPhoneLens.wide,
    this.selectedCodec = ProResCodec.proRes422,
    this.aspectRatio = CinemaAspectRatio.scope239,
    this.gridType = GridOverlayType.ruleOfThirds,
    this.isVideoMode = false,
    this.targetFps = 24,
    this.isRecording = false,
    this.isBusy = false,
    this.recordingSeconds = 0,
    this.isFlashOn = false,
    this.errorBanner,
    this.toastMessage,
    this.toastNonce = 0,
  });

  CinemaTone get activeTone => presets[selectedToneIndex];
  List<double> get effectiveMatrix => activeTone.scaledMatrix(lutIntensity);

  CinemaCameraState copyWith({
    int? textureId,
    bool? isInitializing,
    bool? supportsProRes,
    String? sensorResolution,
    List<CinemaTone>? presets,
    int? selectedToneIndex,
    double? lutIntensity,
    double? exposureBias,
    IPhoneLens? selectedLens,
    ProResCodec? selectedCodec,
    CinemaAspectRatio? aspectRatio,
    GridOverlayType? gridType,
    bool? isVideoMode,
    int? targetFps,
    bool? isRecording,
    bool? isBusy,
    int? recordingSeconds,
    bool? isFlashOn,
    String? errorBanner,
    bool clearError = false,
    String? toastMessage,
    int? toastNonce,
  }) {
    return CinemaCameraState(
      textureId: textureId ?? this.textureId,
      isInitializing: isInitializing ?? this.isInitializing,
      supportsProRes: supportsProRes ?? this.supportsProRes,
      sensorResolution: sensorResolution ?? this.sensorResolution,
      presets: presets ?? this.presets,
      selectedToneIndex: selectedToneIndex ?? this.selectedToneIndex,
      lutIntensity: lutIntensity ?? this.lutIntensity,
      exposureBias: exposureBias ?? this.exposureBias,
      selectedLens: selectedLens ?? this.selectedLens,
      selectedCodec: selectedCodec ?? this.selectedCodec,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      gridType: gridType ?? this.gridType,
      isVideoMode: isVideoMode ?? this.isVideoMode,
      targetFps: targetFps ?? this.targetFps,
      isRecording: isRecording ?? this.isRecording,
      isBusy: isBusy ?? this.isBusy,
      recordingSeconds: recordingSeconds ?? this.recordingSeconds,
      isFlashOn: isFlashOn ?? this.isFlashOn,
      errorBanner: clearError ? null : (errorBanner ?? this.errorBanner),
      toastMessage: toastMessage ?? this.toastMessage,
      toastNonce: toastNonce ?? this.toastNonce,
    );
  }
}

class CinemaCameraNotifier extends Notifier<CinemaCameraState> {
  final NativeCinemaCameraDataSource _dataSource =
      NativeCinemaCameraDataSource();
  Timer? _recTimer;

  @override
  CinemaCameraState build() {
    ref.onDispose(() {
      _recTimer?.cancel();
      _dataSource.dispose();
    });
    const source = CinemaTonesPresetSource();
    Future.microtask(initialize);
    return CinemaCameraState(presets: source.getPresets());
  }

  Future<void> initialize() async {
    try {
      state = state.copyWith(isInitializing: true, clearError: true);
      final init = await _dataSource.initialize(
        lens: state.selectedLens.nativeKey,
        fps: state.targetFps,
      );
      state = state.copyWith(
        textureId: init.textureId,
        supportsProRes: init.supportsProRes,
        sensorResolution: init.sensorResolution,
        selectedCodec: init.supportsProRes
            ? state.selectedCodec
            : ProResCodec.hevc,
        isInitializing: false,
      );
    } on PlatformException catch (e) {
      state = state.copyWith(
        isInitializing: false,
        errorBanner: e.message ?? 'Gagal menginisialisasi sensor iPhone.',
      );
    }
  }

  Future<void> switchLens(IPhoneLens lens) async {
    if (state.isRecording || state.isBusy) return;
    try {
      state = state.copyWith(
        selectedLens: lens,
        isInitializing: true,
        clearError: true,
      );
      final init = await _dataSource.switchLens(
        lens: lens.nativeKey,
        fps: state.targetFps,
      );
      state = state.copyWith(
        textureId: init.textureId,
        supportsProRes: init.supportsProRes,
        sensorResolution: init.sensorResolution,
        selectedCodec: init.supportsProRes
            ? ProResCodec.proRes422
            : ProResCodec.hevc,
        isInitializing: false,
      );
    } on PlatformException catch (e) {
      state = state.copyWith(
        isInitializing: false,
        errorBanner: e.message ?? 'Gagal mengganti lensa.',
      );
    }
  }

  void selectTone(int index) {
    if (index >= 0 && index < state.presets.length) {
      state = state.copyWith(selectedToneIndex: index, clearError: true);
    }
  }

  void addCustomTone(CinemaTone customTone) {
    final updated = [...state.presets, customTone];
    state = state.copyWith(
      presets: updated,
      selectedToneIndex: updated.length - 1,
    );
  }

  void setLutIntensity(double value) {
    state = state.copyWith(lutIntensity: value.clamp(0.0, 1.0));
  }

  Future<void> setExposureBias(double ev) async {
    final clamped = ev.clamp(-3.0, 3.0);
    state = state.copyWith(exposureBias: clamped);
    await _dataSource.setExposureBias(clamped);
  }

  Future<void> tapToFocus(double normX, double normY) async {
    await _dataSource.setFocusAndExposurePoint(normX, normY);
  }

  void cycleAspectRatio() {
    const values = CinemaAspectRatio.values;
    final next = values[(state.aspectRatio.index + 1) % values.length];
    state = state.copyWith(aspectRatio: next);
  }

  void cycleGrid() {
    const values = GridOverlayType.values;
    final next = values[(state.gridType.index + 1) % values.length];
    state = state.copyWith(gridType: next);
  }

  void cycleProResCodec() {
    if (!state.supportsProRes) {
      state = state.copyWith(
        toastMessage: 'Perangkat/lensa ini merekam dalam mode HEVC 10-Bit',
        toastNonce: state.toastNonce + 1,
      );
      return;
    }
    const proResList = [
      ProResCodec.proRes422,
      ProResCodec.proRes422HQ,
      ProResCodec.proRes422LT,
      ProResCodec.proRes422Proxy,
    ];
    final idx = proResList.indexOf(state.selectedCodec);
    final next = proResList[(idx + 1) % proResList.length];
    state = state.copyWith(selectedCodec: next);
  }

  Future<void> toggleFlash() async {
    final next = !state.isFlashOn;
    state = state.copyWith(isFlashOn: next);
    await _dataSource.setFlashMode(next ? 'torch' : 'off');
  }

  Future<void> setMode({required bool video, int fps = 24}) async {
    if (state.isRecording) return;
    state = state.copyWith(
      isVideoMode: video,
      targetFps: fps,
      clearError: true,
    );
    if (video) {
      await _dataSource.setFps(fps);
    }
  }

  Future<void> handleShutter() async {
    if (state.isBusy) return;

    if (!state.isVideoMode) {
      try {
        state = state.copyWith(isBusy: true, clearError: true);
        await _dataSource.capturePhoto(
          matrix: state.effectiveMatrix,
          flashMode: state.isFlashOn ? 'on' : 'off',
        );
        state = state.copyWith(
          isBusy: false,
          toastMessage:
              'Foto tajam ${state.sensorResolution} (${state.activeTone.name}) tersimpan',
          toastNonce: state.toastNonce + 1,
        );
      } on PlatformException catch (e) {
        state = state.copyWith(
          isBusy: false,
          errorBanner: e.message ?? 'Gagal mengambil foto.',
        );
      }
      return;
    }

    if (state.isRecording) {
      try {
        state = state.copyWith(isBusy: true, clearError: true);
        _recTimer?.cancel();
        final res = await _dataSource.stopRecording();
        final status = res['status'] as String? ?? 'saved';
        state = state.copyWith(
          isRecording: false,
          isBusy: false,
          recordingSeconds: 0,
          toastMessage: status == 'saved'
              ? 'Video ${state.selectedCodec.label} tersimpan ke Galeri'
              : 'Sesi rekaman ditutup',
          toastNonce: state.toastNonce + 1,
        );
      } on PlatformException catch (e) {
        state = state.copyWith(
          isRecording: false,
          isBusy: false,
          recordingSeconds: 0,
          errorBanner: e.message ?? 'Gagal menghentikan rekaman.',
        );
      }
    } else {
      try {
        state = state.copyWith(isBusy: true, clearError: true);
        await _dataSource.startRecording(
          codec: state.selectedCodec.nativeKey,
          fps: state.targetFps,
        );
        state = state.copyWith(
          isRecording: true,
          isBusy: false,
          recordingSeconds: 0,
        );
        _recTimer?.cancel();
        _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          state = state.copyWith(
            recordingSeconds: state.recordingSeconds + 1,
          );
        });
      } on PlatformException catch (e) {
        _recTimer?.cancel();
        state = state.copyWith(
          isRecording: false,
          isBusy: false,
          recordingSeconds: 0,
          errorBanner: e.message ?? 'Gagal memulai rekaman ProRes.',
        );
      }
    }
  }
}

final cinemaCameraProvider =
    NotifierProvider<CinemaCameraNotifier, CinemaCameraState>(
  CinemaCameraNotifier.new,
);
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/presentation/screens/camera_screen.dart
// lib/features/cinema_camera/presentation/screens/camera_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../about/presentation/screens/about_screen.dart';
import '../../domain/entities/cinema_camera_enums.dart';
import '../../domain/entities/cinema_tone.dart';
import '../providers/cinema_camera_provider.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  Offset? _focusPoint;
  Timer? _focusTimer;

  @override
  void dispose() {
    _focusTimer?.cancel();
    super.dispose();
  }

  String _formatTimecode(int totalSeconds) {
    final hours = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  void _showCustomLutDialog() {
    double warmth = 0.0;
    double contrast = 1.05;
    double saturation = 1.05;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF161619),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Buat Custom Cinema LUT',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Warmth / Temperature: ${warmth.toStringAsFixed(0)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    Slider(
                      activeColor: Colors.amber,
                      min: -20,
                      max: 20,
                      value: warmth,
                      onChanged: (v) => setModalState(() => warmth = v),
                    ),
                    Text(
                      'Contrast: ${contrast.toStringAsFixed(2)}x',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    Slider(
                      activeColor: Colors.amber,
                      min: 0.8,
                      max: 1.4,
                      value: contrast,
                      onChanged: (v) => setModalState(() => contrast = v),
                    ),
                    Text(
                      'Saturation: ${saturation.toStringAsFixed(2)}x',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    Slider(
                      activeColor: Colors.amber,
                      min: 0.5,
                      max: 1.5,
                      value: saturation,
                      onChanged: (v) => setModalState(() => saturation = v),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        onPressed: () {
                          final s = saturation;
                          final c = contrast;
                          final matrix = <double>[
                            c * (0.299 + 0.701 * s), 0.587 * (1 - s) * c, 0.114 * (1 - s) * c, 0, warmth,
                            0.299 * (1 - s) * c, c * (0.587 + 0.413 * s), 0.114 * (1 - s) * c, 0, warmth * 0.3,
                            0.299 * (1 - s) * c, 0.587 * (1 - s) * c, c * (0.114 + 0.886 * s), 0, -warmth * 0.8,
                            0, 0, 0, 1, 0,
                          ];
                          ref.read(cinemaCameraProvider.notifier).addCustomTone(
                                CinemaTone(
                                  id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                                  name: 'CUSTOM LUT',
                                  subtitle: 'User Grade',
                                  matrix: matrix,
                                ),
                              );
                          Navigator.pop(ctx);
                        },
                        child: const Text(
                          'Terapkan Custom LUT',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cinemaCameraProvider);
    final notifier = ref.read(cinemaCameraProvider.notifier);

    ref.listen<int>(
      cinemaCameraProvider.select((s) => s.toastNonce),
      (_, __) {
        final msg = ref.read(cinemaCameraProvider).toastMessage;
        if (msg != null && mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: const Color(0xFF232329),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            final isLandscape = orientation == Orientation.landscape;
            if (isLandscape) {
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        _buildTopToolbar(state, notifier),
                        Expanded(child: _buildViewfinder(state, notifier, isLandscape: true)),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 280,
                    child: SingleChildScrollView(
                      child: _buildControlDeck(state, notifier, compact: true),
                    ),
                  ),
                ],
              );
            }
            return Column(
              children: [
                _buildTopToolbar(state, notifier),
                Expanded(child: _buildViewfinder(state, notifier, isLandscape: false)),
                _buildControlDeck(state, notifier, compact: false),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopToolbar(CinemaCameraState state, CinemaCameraNotifier notifier) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              notifier.toggleFlash();
            },
            icon: Icon(
              state.isFlashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              color: state.isFlashOn ? Colors.amber : Colors.white70,
              size: 21,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              notifier.cycleAspectRatio();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.amber,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                state.aspectRatio.label,
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w800,
                  fontSize: 10.5,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              notifier.cycleProResCodec();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: state.supportsProRes ? Colors.amberAccent : Colors.white24,
                ),
              ),
              child: Text(
                state.selectedCodec.label,
                style: TextStyle(
                  color: state.supportsProRes ? Colors.amberAccent : Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                ),
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              notifier.cycleGrid();
            },
            icon: Icon(
              Icons.tag_rounded,
              color: state.gridType == GridOverlayType.none
                  ? Colors.white54
                  : Colors.amberAccent,
              size: 20,
            ),
          ),
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
              );
            },
            icon: const Icon(
              Icons.info_outline_rounded,
              color: Colors.white70,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewfinder(
    CinemaCameraState state,
    CinemaCameraNotifier notifier, {
    required bool isLandscape,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapDown: (details) {
            final nx = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
            final ny = (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);
            HapticFeedback.selectionClick();
            notifier.tapToFocus(nx, ny);
            _focusTimer?.cancel();
            setState(() => _focusPoint = details.localPosition);
            _focusTimer = Timer(const Duration(seconds: 2), () {
              if (mounted) setState(() => _focusPoint = null);
            });
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (state.isInitializing || state.textureId < 0)
                const Center(
                  child: CircularProgressIndicator(color: Colors.amber),
                )
              else
                ColorFiltered(
                  colorFilter: ColorFilter.matrix(state.effectiveMatrix),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: isLandscape ? 1920 : 1080,
                      height: isLandscape ? 1080 : 1920,
                      child: Texture(textureId: state.textureId),
                    ),
                  ),
                ),

              if (state.aspectRatio.ratio != null)
                _AspectMask(ratio: state.aspectRatio.ratio!),

              if (state.gridType != GridOverlayType.none)
                IgnorePointer(
                  child: CustomPaint(
                    painter: _GridPainter(state.gridType),
                  ),
                ),

              if (_focusPoint != null)
                Positioned(
                  left: _focusPoint!.dx - 30,
                  top: _focusPoint!.dy - 30,
                  child: IgnorePointer(
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.amberAccent, width: 1.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),

              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.circle, color: Colors.amber, size: 8),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '${state.activeTone.name} | ${state.activeTone.subtitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (state.isRecording)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.red.shade700,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.circle, color: Colors.white, size: 8),
                            const SizedBox(width: 6),
                            Text(
                              'REC ${_formatTimecode(state.recordingSeconds)}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          state.sensorResolution,
                          style: const TextStyle(
                            color: Colors.amberAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: IPhoneLens.values.map((lens) {
                        final selected = state.selectedLens == lens;
                        return GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            notifier.switchLens(lens);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: selected ? Colors.amber : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              lens.label,
                              style: TextStyle(
                                color: selected ? Colors.black : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControlDeck(
    CinemaCameraState state,
    CinemaCameraNotifier notifier, {
    required bool compact,
  }) {
    return Container(
      color: const Color(0xFF0B0B0D),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.movie_filter_outlined, color: Colors.amber, size: 15),
              const SizedBox(width: 4),
              Text(
                'LUT ${(state.lutIntensity * 100).round()}%',
                style: const TextStyle(color: Colors.white70, fontSize: 10.5),
              ),
              Expanded(
                child: Slider(
                  activeColor: Colors.amber,
                  inactiveColor: Colors.white24,
                  min: 0.0,
                  max: 1.0,
                  value: state.lutIntensity,
                  onChanged: notifier.setLutIntensity,
                ),
              ),
              const Icon(Icons.wb_sunny_outlined, color: Colors.white70, size: 15),
              const SizedBox(width: 4),
              Text(
                '${state.exposureBias >= 0 ? "+" : ""}${state.exposureBias.toStringAsFixed(1)}',
                style: const TextStyle(color: Colors.white70, fontSize: 10.5),
              ),
              Expanded(
                child: Slider(
                  activeColor: Colors.white,
                  inactiveColor: Colors.white24,
                  min: -2.0,
                  max: 2.0,
                  value: state.exposureBias,
                  onChanged: notifier.setExposureBias,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 60,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: state.presets.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, idx) {
                if (idx == 0) {
                  return GestureDetector(
                    onTap: _showCustomLutDialog,
                    child: Container(
                      width: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF17171B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.55)),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.tune_rounded, color: Colors.amber, size: 18),
                          SizedBox(height: 4),
                          Text(
                            '+ CUSTOM',
                            style: TextStyle(
                              color: Colors.amber,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final presetIndex = idx - 1;
                final preset = state.presets[presetIndex];
                final selected = presetIndex == state.selectedToneIndex;

                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    notifier.selectTone(presetIndex);
                  },
                  child: Container(
                    width: 122,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF231E12) : const Color(0xFF17171B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? Colors.amber : Colors.white12,
                        width: selected ? 1.4 : 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.circle,
                              size: 7,
                              color: selected ? Colors.amber : Colors.white54,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                preset.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected ? Colors.amberAccent : Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          preset.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54, fontSize: 9.5),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFF18181D),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Wrap(
              alignment: WrapAlignment.center,
              children: [
                _ModePill(
                  label: 'PHOTO',
                  selected: !state.isVideoMode,
                  onTap: () => notifier.setMode(video: false),
                ),
                _ModePill(
                  label: 'VIDEO 24FPS',
                  selected: state.isVideoMode && state.targetFps == 24,
                  onTap: () => notifier.setMode(video: true, fps: 24),
                ),
                _ModePill(
                  label: 'VIDEO 60FPS',
                  selected: state.isVideoMode && state.targetFps == 60,
                  onTap: () => notifier.setMode(video: true, fps: 60),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              notifier.handleShutter();
            },
            child: Container(
              width: compact ? 58 : 66,
              height: compact ? 58 : 66,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3.5),
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: state.isRecording ? 24 : (compact ? 44 : 50),
                  height: state.isRecording ? 24 : (compact ? 44 : 50),
                  decoration: BoxDecoration(
                    color: state.isVideoMode ? Colors.redAccent : Colors.white,
                    borderRadius: BorderRadius.circular(state.isRecording ? 6 : 50),
                  ),
                ),
              ),
            ),
          ),
          if (state.errorBanner != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                state.errorBanner!,
                style: const TextStyle(color: Colors.black87, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.amber : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontWeight: FontWeight.bold,
            fontSize: 10.5,
          ),
        ),
      ),
    );
  }
}

class _AspectMask extends StatelessWidget {
  final double ratio;
  const _AspectMask({required this.ratio});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          final frameH = (w / ratio).clamp(0.0, h);
          final barH = ((h - frameH) / 2).clamp(0.0, h);
          return Column(
            children: [
              Container(height: barH, color: Colors.black.withValues(alpha: 0.75)),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.symmetric(
                      horizontal: BorderSide(
                        color: Colors.amberAccent.withValues(alpha: 0.45),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
              Container(height: barH, color: Colors.black.withValues(alpha: 0.75)),
            ],
          );
        },
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final GridOverlayType type;
  _GridPainter(this.type);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 0.8;

    if (type == GridOverlayType.ruleOfThirds) {
      for (int i = 1; i <= 2; i++) {
        canvas.drawLine(Offset(size.width * i / 3, 0), Offset(size.width * i / 3, size.height), paint);
        canvas.drawLine(Offset(0, size.height * i / 3), Offset(size.width, size.height * i / 3), paint);
      }
    } else if (type == GridOverlayType.goldenRatio) {
      const p = 0.382;
      canvas.drawLine(Offset(size.width * p, 0), Offset(size.width * p, size.height), paint);
      canvas.drawLine(Offset(size.width * (1 - p), 0), Offset(size.width * (1 - p), size.height), paint);
      canvas.drawLine(Offset(0, size.height * p), Offset(size.width, size.height * p), paint);
      canvas.drawLine(Offset(0, size.height * (1 - p)), Offset(size.width, size.height * (1 - p)), paint);
    } else if (type == GridOverlayType.crosshair) {
      final cx = size.width / 2;
      final cy = size.height / 2;
      canvas.drawLine(Offset(cx - 20, cy), Offset(cx + 20, cy), paint);
      canvas.drawLine(Offset(cx, cy - 20), Offset(cx, cy + 20), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => oldDelegate.type != type;
}
DART_FILE_EOF

PKG_NAME=$(grep '^name:' pubspec.yaml | awk '{print $2}' | tr -d '\r')
if [ -f "test/widget_test.dart" ] && [ -n "$PKG_NAME" ]; then
  cat << DART_TEST_EOF > test/widget_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:${PKG_NAME}/main.dart';

void main() {
  testWidgets('CineLensApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CineLensApp()));
    expect(find.byType(CineLensApp), findsOneWidget);
  });
}
DART_TEST_EOF
fi

echo "=== 1. Bersihkan Build Lama & Cadangkan Konfigurasi iOS ==="
rm -rf build/ios
mkdir -p /tmp/ios_backup

if [ -f "ios/Runner/Info.plist" ]; then
  cp ios/Runner/Info.plist /tmp/ios_backup/Info.plist
fi

if [ -d "ios/Runner/Assets.xcassets" ]; then
  cp -r ios/Runner/Assets.xcassets /tmp/ios_backup/Assets.xcassets
fi

echo "=== 2. Siapkan Struktur Native iOS, ProRes Engine & Orientasi ==="
flutter create --platforms=ios .

if [ -f "/tmp/ios_backup/Info.plist" ]; then
  cp /tmp/ios_backup/Info.plist ios/Runner/Info.plist
fi

/usr/libexec/PlistBuddy -c "Delete :NSCameraUsageDescription" ios/Runner/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 'CineLens membutuhkan akses kamera untuk merekam video ProRes dan foto resolusi penuh.'" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Delete :NSMicrophoneUsageDescription" ios/Runner/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'CineLens membutuhkan akses mikrofon untuk merekam audio video sinematik.'" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Delete :NSPhotoLibraryAddUsageDescription" ios/Runner/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSPhotoLibraryAddUsageDescription string 'CineLens membutuhkan izin menyimpan foto dan video ProRes ke Galeri.'" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Delete :NSPhotoLibraryUsageDescription" ios/Runner/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSPhotoLibraryUsageDescription string 'CineLens membutuhkan akses Galeri untuk menyimpan foto dan video.'" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Delete :UIApplicationSceneManifest" ios/Runner/Info.plist 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Delete :UISupportedInterfaceOrientations" ios/Runner/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations array" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationPortrait" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:1 string UIInterfaceOrientationLandscapeLeft" ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations:2 string UIInterfaceOrientationLandscapeRight" ios/Runner/Info.plist

if [ -d "/tmp/ios_backup/Assets.xcassets" ]; then
  rm -rf ios/Runner/Assets.xcassets
  cp -r /tmp/ios_backup/Assets.xcassets ios/Runner/Assets.xcassets
fi

cat << 'SWIFT_FILE_EOF' > ios/Runner/AppDelegate.swift
// ios/Runner/AppDelegate.swift

import Flutter
import UIKit
import AVFoundation
import CoreImage
import Photos

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(

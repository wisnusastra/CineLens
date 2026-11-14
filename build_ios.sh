#!/bin/bash
set -e

echo "=== 0. Persiapan Struktur Folder Modular CineLens iOS ==="
if [ -d "features" ] && [ -d "lib/features" ]; then
  rm -rf features
fi

rm -rf lib/features/options

mkdir -p lib/features/about/presentation/screens
mkdir -p lib/features/cinema_camera/domain/entities
mkdir -p lib/features/cinema_camera/data/datasources
mkdir -p lib/features/cinema_camera/presentation/providers
mkdir -p lib/features/cinema_camera/presentation/screens

echo "=== 1. Generate Otomatis Seluruh File Dart Modular ==="

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
  ]);

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(
    const ProviderScope(
      child: CineLensApp(),
    ),
  );
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
import 'package:share_plus/share_plus.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String developerName = 'Wisnu Sastra Wijaya';
  static const String supportEmail = 'wisnusastra9@gmail.com';
  static const String appVersion = '2.0.0 ProRes Edition';

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

  void _sendFeedback() {
    Share.share(
      'Halo $developerName,\n\n'
      'Saya ingin memberikan masukan / dukungan untuk aplikasi CineLens iOS:\n\n'
      '(Tulis pesan Anda di sini)\n\n'
      'Kirim ke: $supportEmail',
      subject: 'CineLens iOS - Support & Masukan',
    );
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
                      color: Colors.amber.withOpacity(0.15),
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
                    'Native Apple ProRes Cinema & Full-Sensor Camera',
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
                        backgroundColor: Colors.amber.withOpacity(0.2),
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
        name: 'VISION3

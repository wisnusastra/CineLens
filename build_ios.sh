#!/bin/bash
set -e

echo "=== 0. Sinkronisasi Otomatis Seluruh File Modul Flutter ==="
if [ -d "features" ] && [ -d "lib/features" ]; then
  rm -rf features
fi

mkdir -p lib/features/about/presentation/screens
mkdir -p lib/features/options/domain/entities
mkdir -p lib/features/options/presentation/providers
mkdir -p lib/features/options/presentation/widgets
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
  static const String appVersion = '1.0.0';

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
                    'Cinematic Camera & Real-Time Color Grading',
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

cat << 'DART_FILE_EOF' > lib/features/options/domain/entities/camera_options_state.dart
// lib/features/options/domain/entities/camera_options_state.dart

enum GridOverlayType {
  none('Off'),
  ruleOfThirds('Rule of Thirds'),
  goldenRatio('Golden Ratio'),
  crosshair('Center Crosshair');

  final String label;
  const GridOverlayType(this.label);
}

enum CinemaAspectRatio {
  full('Full Sensor', null),
  widescreen16x9('16:9 Widescreen', 16 / 9),
  anamorphic239('2.39:1 CinemaScope', 2.39),
  classic4x3('4:3 Classic', 4 / 3);

  final String label;
  final double? ratio;
  const CinemaAspectRatio(this.label, this.ratio);
}

class CameraOptionsState {
  final GridOverlayType gridType;
  final CinemaAspectRatio aspectRatio;
  final bool showTelemetryHud;
  final bool hapticFeedback;
  final bool mirrorFrontCamera;

  const CameraOptionsState({
    this.gridType = GridOverlayType.ruleOfThirds,
    this.aspectRatio = CinemaAspectRatio.full,
    this.showTelemetryHud = true,
    this.hapticFeedback = true,
    this.mirrorFrontCamera = true,
  });

  CameraOptionsState copyWith({
    GridOverlayType? gridType,
    CinemaAspectRatio? aspectRatio,
    bool? showTelemetryHud,
    bool? hapticFeedback,
    bool? mirrorFrontCamera,
  }) {
    return CameraOptionsState(
      gridType: gridType ?? this.gridType,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      showTelemetryHud: showTelemetryHud ?? this.showTelemetryHud,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      mirrorFrontCamera: mirrorFrontCamera ?? this.mirrorFrontCamera,
    );
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/options/presentation/providers/camera_options_provider.dart
// lib/features/options/presentation/providers/camera_options_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/camera_options_state.dart';

class CameraOptionsNotifier extends Notifier<CameraOptionsState> {
  @override
  CameraOptionsState build() {
    return const CameraOptionsState();
  }

  void setGridType(GridOverlayType type) {
    state = state.copyWith(gridType: type);
  }

  void setAspectRatio(CinemaAspectRatio ratio) {
    state = state.copyWith(aspectRatio: ratio);
  }

  void toggleTelemetryHud(bool value) {
    state = state.copyWith(showTelemetryHud: value);
  }

  void toggleHapticFeedback(bool value) {
    state = state.copyWith(hapticFeedback: value);
  }

  void toggleMirrorFrontCamera(bool value) {
    state = state.copyWith(mirrorFrontCamera: value);
  }

  void resetDefaults() {
    state = const CameraOptionsState();
  }
}

final cameraOptionsProvider =
    NotifierProvider<CameraOptionsNotifier, CameraOptionsState>(
  CameraOptionsNotifier.new,
);
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/options/presentation/widgets/cinematic_viewfinder_overlay.dart
// lib/features/options/presentation/widgets/cinematic_viewfinder_overlay.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/camera_options_state.dart';
import '../providers/camera_options_provider.dart';

class CinematicViewfinderOverlay extends ConsumerWidget {
  final String activeToneName;

  const CinematicViewfinderOverlay({
    super.key,
    this.activeToneName = 'Standard',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(cameraOptionsProvider);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (options.gridType != GridOverlayType.none)
            CustomPaint(
              painter: _GridOverlayPainter(gridType: options.gridType),
            ),
          if (options.aspectRatio.ratio != null)
            LayoutBuilder(
              builder: (context, constraints) {
                final screenW = constraints.maxWidth;
                final screenH = constraints.maxHeight;
                final targetRatio = isLandscape
                    ? options.aspectRatio.ratio!
                    : (1 / options.aspectRatio.ratio!);

                double frameW = screenW;
                double frameH = screenW / targetRatio;

                if (frameH > screenH) {
                  frameH = screenH;
                  frameW = screenH * targetRatio;
                }

                final barH = ((screenH - frameH) / 2).clamp(0.0, screenH);
                final barW = ((screenW - frameW) / 2).clamp(0.0, screenW);

                return Stack(
                  children: [
                    if (barH > 0) ...[
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: barH,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: barH,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                    ],
                    if (barW > 0) ...[
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: 0,
                        width: barW,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: barW,
                        child: Container(color: Colors.black.withOpacity(0.72)),
                      ),
                    ],
                    Center(
                      child: Container(
                        width: frameW,
                        height: frameH,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.amberAccent.withOpacity(0.45),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          if (options.showTelemetryHud)
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: const EdgeInsets.all(14),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.fiber_manual_record,
                        color: Colors.amber,
                        size: 10,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${isLandscape ? "LANDSCAPE" : "PORTRAIT"}  •  '
                        '${options.aspectRatio.label.toUpperCase()}  •  '
                        'LUT: ${activeToneName.toUpperCase()}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GridOverlayPainter extends CustomPainter {
  final GridOverlayType gridType;

  _GridOverlayPainter({required this.gridType});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..strokeWidth = 0.9;

    if (gridType == GridOverlayType.ruleOfThirds) {
      for (int i = 1; i <= 2; i++) {
        final dx = size.width * (i / 3);
        final dy = size.height * (i / 3);
        canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
        canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
      }
    } else if (gridType == GridOverlayType.goldenRatio) {
      const phi = 0.382;
      const invPhi = 1 - phi;
      canvas.drawLine(Offset(size.width * phi, 0),
          Offset(size.width * phi, size.height), paint);
      canvas.drawLine(Offset(size.width * invPhi, 0),
          Offset(size.width * invPhi, size.height), paint);
      canvas.drawLine(Offset(0, size.height * phi),
          Offset(size.width, size.height * phi), paint);
      canvas.drawLine(Offset(0, size.height * invPhi),
          Offset(size.width, size.height * invPhi), paint);
    } else if (gridType == GridOverlayType.crosshair) {
      final cx = size.width / 2;
      final cy = size.height / 2;
      canvas.drawLine(Offset(cx - 24, cy), Offset(cx + 24, cy), paint);
      canvas.drawLine(Offset(cx, cy - 24), Offset(cx, cy + 24), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridOverlayPainter oldDelegate) {
    return oldDelegate.gridType != gridType;
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/options/presentation/widgets/camera_options_sheet.dart
// lib/features/options/presentation/widgets/camera_options_sheet.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../about/presentation/screens/about_screen.dart';
import '../../domain/entities/camera_options_state.dart';
import '../providers/camera_options_provider.dart';

class CameraOptionsButton extends ConsumerWidget {
  const CameraOptionsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hapticEnabled = ref.watch(
      cameraOptionsProvider.select((s) => s.hapticFeedback),
    );

    return Material(
      color: Colors.black.withOpacity(0.55),
      shape: const CircleBorder(
        side: BorderSide(color: Colors.white24, width: 1),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          if (hapticEnabled) HapticFeedback.lightImpact();
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            backgroundColor: const Color(0xFF141416),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            builder: (_) => const CameraOptionsSheet(),
          );
        },
        child: const Padding(
          padding: EdgeInsets.all(11),
          child: Icon(
            Icons.tune_rounded,
            color: Colors.amberAccent,
            size: 22,
          ),
        ),
      ),
    );
  }
}

class CameraOptionsSheet extends ConsumerWidget {
  const CameraOptionsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(cameraOptionsProvider);
    final notifier = ref.read(cameraOptionsProvider.notifier);

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'CineLens Options',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      if (options.hapticFeedback) HapticFeedback.selectionClick();
                      notifier.resetDefaults();
                    },
                    icon: const Icon(Icons.refresh, size: 16, color: Colors.amber),
                    label: const Text(
                      'Reset',
                      style: TextStyle(color: Colors.amber),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'PANDUAN GRID KOMPOSISI',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: GridOverlayType.values.map((type) {
                  final selected = options.gridType == type;
                  return ChoiceChip(
                    label: Text(type.label),
                    selected: selected,
                    selectedColor: Colors.amber,
                    backgroundColor: const Color(0xFF222226),
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                    onSelected: (_) {
                      if (options.hapticFeedback) HapticFeedback.selectionClick();
                      notifier.setGridType(type);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              const Text(
                'FRAME GUIDE RASIO SINEMATIK',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: CinemaAspectRatio.values.map((ratio) {
                  final selected = options.aspectRatio == ratio;
                  return ChoiceChip(
                    label: Text(ratio.label),
                    selected: selected,
                    selectedColor: Colors.amber,
                    backgroundColor: const Color(0xFF222226),
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                    onSelected: (_) {
                      if (options.hapticFeedback) HapticFeedback.selectionClick();
                      notifier.setAspectRatio(ratio);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              const Text(
                'PREFERENSI KAMERA & HUD',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E22),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  children: [
                    SwitchListTile(
                      activeColor: Colors.amber,
                      title: const Text(
                        'Tampilkan Telemetry HUD',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Info orientasi, rasio frame, dan LUT aktif di layar',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: options.showTelemetryHud,
                      onChanged: notifier.toggleTelemetryHud,
                    ),
                    const Divider(height: 1, color: Colors.white12),
                    SwitchListTile(
                      activeColor: Colors.amber,
                      title: const Text(
                        'Haptic Feedback (Getar Halus)',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Respons getar saat tombol shutter & preset ditekan',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: options.hapticFeedback,
                      onChanged: notifier.toggleHapticFeedback,
                    ),
                    const Divider(height: 1, color: Colors.white12),
                    SwitchListTile(
                      activeColor: Colors.amber,
                      title: const Text(
                        'Mirror Kamera Depan',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Simpan hasil foto selfie sesuai tampilan pratinjau',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: options.mirrorFrontCamera,
                      onChanged: notifier.toggleMirrorFrontCamera,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.amber.withOpacity(0.4)),
                ),
                tileColor: const Color(0xFF1E1E22),
                leading: const Icon(
                  Icons.info_outline_rounded,
                  color: Colors.amberAccent,
                ),
                title: const Text(
                  'About CineLens iOS',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  'Developer: Wisnu Sastra Wijaya • Support & Masukan',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white54,
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const AboutScreen(),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/domain/entities/cinema_tone.dart
// lib/features/cinema_camera/domain/entities/cinema_tone.dart

class CinemaTone {
  final String id;
  final String name;
  final String description;
  final String subtitle;
  final String category;
  final List<double> matrix;

  const CinemaTone({
    this.id = '',
    required this.name,
    this.description = '',
    this.subtitle = '',
    this.category = 'Cinema',
    required this.matrix,
  });

  bool get isValidMatrix => matrix.length == 20;
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
        id: 'standard',
        name: 'Standard',
        description: 'Natural sensor color profile',
        matrix: <double>[
          1.0, 0.0, 0.0, 0.0, 0.0,
          0.0, 1.0, 0.0, 0.0, 0.0,
          0.0, 0.0, 1.0, 0.0, 0.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'kodak_2383',
        name: 'Kodak 2383',
        description: 'Warm highlight roll-off & rich contrast',
        matrix: <double>[
          1.12, 0.04, -0.02, 0.0, 6.0,
          0.02, 1.06, 0.01, 0.0, 2.0,
          -0.04, 0.03, 0.94, 0.0, -4.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'teal_orange',
        name: 'Teal & Orange',
        description: 'Hollywood blockbuster color separation',
        matrix: <double>[
          1.18, 0.05, -0.08, 0.0, 8.0,
          -0.02, 1.02, 0.06, 0.0, 0.0,
          -0.06, 0.12, 1.10, 0.0, 6.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'fuji_velvia',
        name: 'Fuji Velvia',
        description: 'Deep shadows & vivid landscape saturation',
        matrix: <double>[
          1.20, -0.05, -0.03, 0.0, -4.0,
          -0.03, 1.18, -0.03, 0.0, -4.0,
          -0.02, -0.04, 1.22, 0.0, -2.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'noir_bw',
        name: 'Noir B&W',
        description: 'High-contrast monochrome cinema film',
        matrix: <double>[
          0.33, 0.59, 0.11, 0.0, -8.0,
          0.33, 0.59, 0.11, 0.0, -8.0,
          0.33, 0.59, 0.11, 0.0, -8.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'golden_hour',
        name: 'Golden Hour',
        description: 'Amber sunset warmth & soft skin tones',
        matrix: <double>[
          1.16, 0.08, 0.0, 0.0, 10.0,
          0.03, 1.05, 0.0, 0.0, 4.0,
          -0.05, 0.0, 0.85, 0.0, -6.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
      CinemaTone(
        id: 'vintage_16mm',
        name: 'Vintage 16mm',
        description: 'Faded blacks & nostalgic analog grain feel',
        matrix: <double>[
          1.05, 0.09, 0.02, 0.0, 12.0,
          0.04, 1.00, 0.04, 0.0, 8.0,
          0.0, 0.06, 0.88, 0.0, 10.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ],
      ),
    ];
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/cinema_camera/presentation/providers/cinema_camera_provider.dart
// lib/features/cinema_camera/presentation/providers/cinema_camera_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/datasources/cinema_tones_preset_source.dart';
import '../../domain/entities/cinema_tone.dart';

class CinemaCameraState {
  final List<CinemaTone> presets;
  final int selectedToneIndex;
  final bool isVideoMode;
  final bool isRecording;
  final bool isCapturing;
  final int cameraIndex;

  const CinemaCameraState({
    required this.presets,
    this.selectedToneIndex = 0,
    this.isVideoMode = false,
    this.isRecording = false,
    this.isCapturing = false,
    this.cameraIndex = 0,
  });

  CinemaTone get activeTone => presets[selectedToneIndex];

  CinemaCameraState copyWith({
    List<CinemaTone>? presets,
    int? selectedToneIndex,
    bool? isVideoMode,
    bool? isRecording,
    bool? isCapturing,
    int? cameraIndex,
  }) {
    return CinemaCameraState(
      presets: presets ?? this.presets,
      selectedToneIndex: selectedToneIndex ?? this.selectedToneIndex,
      isVideoMode: isVideoMode ?? this.isVideoMode,
      isRecording: isRecording ?? this.isRecording,
      isCapturing: isCapturing ?? this.isCapturing,
      cameraIndex: cameraIndex ?? this.cameraIndex,
    );
  }
}

class CinemaCameraNotifier extends Notifier<CinemaCameraState> {
  @override
  CinemaCameraState build() {
    const source = CinemaTonesPresetSource();
    return CinemaCameraState(presets: source.getPresets());
  }

  void selectTone(int index) {
    if (index >= 0 && index < state.presets.length) {
      state = state.copyWith(selectedToneIndex: index);
    }
  }

  void setVideoMode(bool value) {
    if (!state.isRecording) {
      state = state.copyWith(isVideoMode: value);
    }
  }

  void setRecording(bool value) {
    state = state.copyWith(isRecording: value);
  }

  void setCapturing(bool value) {
    state = state.copyWith(isCapturing: value);
  }

  void setCameraIndex(int index) {
    state = state.copyWith(cameraIndex: index);
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
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import '../../../options/presentation/providers/camera_options_provider.dart';
import '../../../options/presentation/widgets/camera_options_sheet.dart';
import '../../../options/presentation/widgets/cinematic_viewfinder_overlay.dart';
import '../providers/cinema_camera_provider.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  FlashMode _flashMode = FlashMode.off;
  bool _isInitializing = true;
  String? _errorMessage;
  Offset? _focusPoint;
  Timer? _focusTimer;
  Timer? _recordTimer;
  int _recordSeconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _recordTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      final index = ref.read(cinemaCameraProvider).cameraIndex;
      if (_cameras.isNotEmpty) {
        _setupCameraController(_cameras[index % _cameras.length]);
      }
    }
  }

  Future<void> _initCameras() async {
    try {
      setState(() {
        _isInitializing = true;
        _errorMessage = null;
      });
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Kamera tidak ditemukan pada perangkat ini.';
        });
        return;
      }
      await _setupCameraController(_cameras.first);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = 'Gagal mengakses kamera: $e';
      });
    }
  }

  Future<void> _setupCameraController(CameraDescription description) async {
    final oldController = _controller;
    final newController = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    try {
      await oldController?.dispose();
      await newController.initialize();
      await newController.setFlashMode(_flashMode);

      if (!mounted) {
        await newController.dispose();
        return;
      }

      setState(() {
        _controller = newController;
        _isInitializing = false;
        _errorMessage = null;
      });
    } catch (e) {
      await newController.dispose();
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = 'Inisialisasi kamera gagal: $e';
      });
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    final cameraState = ref.read(cinemaCameraProvider);
    if (cameraState.isRecording) return;

    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;
    if (hapticEnabled) HapticFeedback.lightImpact();

    final nextIndex = (cameraState.cameraIndex + 1) % _cameras.length;
    ref.read(cinemaCameraProvider.notifier).setCameraIndex(nextIndex);

    setState(() => _isInitializing = true);
    await _setupCameraController(_cameras[nextIndex]);
  }

  Future<void> _cycleFlashMode() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;
    if (hapticEnabled) HapticFeedback.selectionClick();

    final nextMode = switch (_flashMode) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      FlashMode.always => FlashMode.torch,
      FlashMode.torch => FlashMode.off,
    };

    try {
      await controller.setFlashMode(nextMode);
      setState(() => _flashMode = nextMode);
    } catch (_) {}
  }

  Future<void> _onTapToFocus(
    TapDownDetails details,
    BoxConstraints constraints,
  ) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final dx = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final dy =
        (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    try {
      await controller.setFocusPoint(Offset(dx, dy));
      await controller.setExposurePoint(Offset(dx, dy));
    } catch (_) {}

    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;
    if (hapticEnabled) HapticFeedback.selectionClick();

    _focusTimer?.cancel();
    setState(() => _focusPoint = details.localPosition);
    _focusTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _focusPoint = null);
    });
  }

  Future<void> _handleShutterPressed() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final cameraState = ref.read(cinemaCameraProvider);
    final notifier = ref.read(cinemaCameraProvider.notifier);
    final hapticEnabled = ref.read(cameraOptionsProvider).hapticFeedback;

    if (hapticEnabled) HapticFeedback.mediumImpact();

    if (cameraState.isVideoMode) {
      if (cameraState.isRecording) {
        try {
          _recordTimer?.cancel();
          final XFile videoFile = await controller.stopVideoRecording();
          notifier.setRecording(false);
          setState(() => _recordSeconds = 0);

          await Gal.putVideo(videoFile.path);
          _showStatusToast('Video tersimpan ke Galeri');
        } catch (e) {
          notifier.setRecording(false);
          _showStatusToast('Gagal menyimpan video: $e', isError: true);
        }
      } else {
        try {
          await controller.startVideoRecording();
          notifier.setRecording(true);
          setState(() => _recordSeconds = 0);
          _recordTimer?.cancel();
          _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() => _recordSeconds++);
          });
        } catch (e) {
          _showStatusToast('Gagal mulai merekam: $e', isError: true);
        }
      }
      return;
    }

    if (cameraState.isCapturing) return;
    try {
      notifier.setCapturing(true);
      final XFile photoFile = await controller.takePicture();
      await Gal.putImage(photoFile.path);
      _showStatusToast('Foto (${cameraState.activeTone.name}) tersimpan');
    } catch (e) {
      _showStatusToast('Gagal memotret: $e', isError: true);
    } finally {
      notifier.setCapturing(false);
    }
  }

  void _showStatusToast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF232328),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  IconData get _flashIcon => switch (_flashMode) {
        FlashMode.off => Icons.flash_off_rounded,
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.always => Icons.flash_on_rounded,
        FlashMode.torch => Icons.highlight_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cinemaCameraProvider);
    final options = ref.watch(cameraOptionsProvider);
    final activeTone = cameraState.activeTone;

    return Scaffold(
      backgroundColor: Colors.black,
      body: OrientationBuilder(
        builder: (context, orientation) {
          final isLandscape = orientation == Orientation.landscape;

          return LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  _buildCameraViewport(
                    isLandscape: isLandscape,
                    activeToneMatrix: activeTone.matrix,
                    constraints: constraints,
                  ),
                  CinematicViewfinderOverlay(
                    activeToneName: activeTone.name,
                  ),
                  if (_focusPoint != null)
                    Positioned(
                      left: _focusPoint!.dx - 32,
                      top: _focusPoint!.dy - 32,
                      child: IgnorePointer(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.amberAccent,
                              width: 1.6,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  if (cameraState.isRecording)
                    SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          margin: const EdgeInsets.only(top: 14),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.88),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.fiber_manual_record,
                                color: Colors.white,
                                size: 12,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'REC ${_formatDuration(_recordSeconds)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildCircleActionButton(
                              icon: _flashIcon,
                              color: _flashMode == FlashMode.off
                                  ? Colors.white70
                                  : Colors.amberAccent,
                              onTap: _cycleFlashMode,
                            ),
                            const SizedBox(width: 10),
                            const CameraOptionsButton(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isLandscape)
                    _buildLandscapeControls(cameraState, options.hapticFeedback)
                  else
                    _buildPortraitControls(cameraState, options.hapticFeedback),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildCameraViewport({
    required bool isLandscape,
    required List<double> activeToneMatrix,
    required BoxConstraints constraints,
  }) {
    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.amberAccent),
      );
    }

    if (_errorMessage != null ||
        _controller == null ||
        !_controller!.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_rounded,
                color: Colors.white54,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage ?? 'Kamera belum siap.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                ),
                onPressed: _initCameras,
                child: const Text('Coba Lagi'),
              ),
            ],
          ),
        ),
      );
    }

    final previewSize =
        _controller!.value.previewSize ?? const Size(1920, 1080);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _onTapToFocus(details, constraints),
      child: ColorFiltered(

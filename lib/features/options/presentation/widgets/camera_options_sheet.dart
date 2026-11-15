// lib/features/options/presentation/widgets/camera_options_sheet.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../about/presentation/screens/about_screen.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_provider.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_state.dart';
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
    final cameraState = ref.watch(cinemaCameraProvider).valueOrNull;
    final cameraNotifier = ref.read(cinemaCameraProvider.notifier);
    final isBusy = cameraState?.isRecordingVideo ?? false;

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.68,
        minChildSize: 0.45,
        maxChildSize: 0.9,
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
              if (cameraState != null) ...[
                const Text(
                  'RESOLUSI & FRAME RATE',
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
                  children: CaptureResolution.values.map((value) {
                    final selected = cameraState.resolution == value;
                    return ChoiceChip(
                      label: Text(value.label),
                      selected: selected,
                      selectedColor: Colors.amber,
                      backgroundColor: const Color(0xFF222226),
                      labelStyle: TextStyle(
                        color: selected ? Colors.black : Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      onSelected: isBusy
                          ? null
                          : (_) {
                              if (options.hapticFeedback) {
                                HapticFeedback.selectionClick();
                              }
                              _applyProfile(
                                context,
                                () => cameraNotifier.setResolution(value),
                                'resolusi ${value.label}',
                              );
                            },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 6),
                Text(
                  isBusy
                      ? 'Resolusi tidak dapat diubah saat merekam.'
                      : 'MAX memakai sensor penuh untuk foto. Video dibatasi 4K '
                          'agar encoder iOS tetap stabil.',
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: CaptureFrameRate.values.map((value) {
                    final selected = cameraState.frameRate == value;
                    return ChoiceChip(
                      label: Text('${value.label} FPS'),
                      selected: selected,
                      selectedColor: Colors.amber,
                      backgroundColor: const Color(0xFF222226),
                      labelStyle: TextStyle(
                        color: selected ? Colors.black : Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      onSelected: isBusy
                          ? null
                          : (_) {
                              if (options.hapticFeedback) {
                                HapticFeedback.selectionClick();
                              }
                              _applyProfile(
                                context,
                                () => cameraNotifier.setFrameRate(value),
                                'frame rate ${value.label} fps',
                              );
                            },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E22),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: cameraState.videoStabilizationActive
                          ? Colors.amber.withValues(alpha: 0.5)
                          : Colors.white12,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.video_stable_rounded,
                        size: 18,
                        color: cameraState.videoStabilizationActive
                            ? Colors.amber
                            : Colors.white38,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'STABILISASI VIDEO · '
                              '${cameraState.stabilizationLabel}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              cameraState.videoStabilizationActive
                                  ? 'Aktif otomatis. iOS memilih mode terbaik '
                                      'yang didukung format aktif (Cinematic '
                                      'untuk 1080p, Standard untuk 4K).'
                                  : 'Belum aktif. Format aktif menolak '
                                      'stabilisasi, biasanya karena 4K/60. '
                                      'Turunkan ke 1080p untuk hasil '
                                      'selengkapnya.',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 9,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
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

  /// Keeps a failed session rebuild visible instead of silently doing nothing.
  Future<void> _applyProfile(
    BuildContext context,
    Future<void> Function() action,
    String label,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Gagal mengganti $label: ${_describe(error)}'),
          backgroundColor: const Color(0xFFB3261E),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _describe(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}

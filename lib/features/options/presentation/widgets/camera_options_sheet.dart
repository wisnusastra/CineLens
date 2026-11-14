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

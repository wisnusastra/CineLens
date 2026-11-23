// lib/features/options/presentation/widgets/camera_options_sheet.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../about/presentation/screens/about_screen.dart';
import '../../../cinema_camera/domain/entities/pro_capture_capabilities.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_provider.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_state.dart';
import '../../../cinema_camera/presentation/widgets/film_look_section.dart';
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
                      if (options.hapticFeedback)
                        HapticFeedback.selectionClick();
                      notifier.resetDefaults();
                    },
                    icon: const Icon(Icons.refresh,
                        size: 16, color: Colors.amber),
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
                _buildProSection(
                  state: cameraState,
                  notifier: cameraNotifier,
                  haptics: options.hapticFeedback,
                ),
                const SizedBox(height: 20),
                FilmLookSection(
                  state: cameraState,
                  notifier: cameraNotifier,
                  haptics: options.hapticFeedback,
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
                      if (options.hapticFeedback)
                        HapticFeedback.selectionClick();
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
                      if (options.hapticFeedback)
                        HapticFeedback.selectionClick();
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
                      activeThumbColor: Colors.amber,
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
                      activeThumbColor: Colors.amber,
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
                      activeThumbColor: Colors.amber,
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

  /// Manual exposure / white balance / focus / Apple Log.
  ///
  /// Everything is gated on [ProCaptureCapabilities] because the hardware
  /// differs per iPhone: Apple Log needs an iPhone 15 Pro or newer, ProRes an
  /// iPhone 13 Pro or newer, and the ISO/shutter ranges come from the format the
  /// `camera` plugin currently runs.
  Widget _buildProSection({
    required CinemaCameraState state,
    required CinemaCameraNotifier notifier,
    required bool haptics,
  }) {
    final caps = state.proCapabilities;
    final isRecording = state.isRecordingVideo;

    void tap() {
      if (haptics) HapticFeedback.selectionClick();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'KONTROL PRO (MANUAL)',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        if (!caps.available)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: const Text(
              'Menunggu kamera siap. Shutter, ISO, white balance, focus, '
              'Apple Log, dan ProRes muncul setelah pratinjau hidup — batas '
              'tiap kontrol dibaca langsung dari sensor.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 10,
                height: 1.35,
              ),
            ),
          )
        else ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: caps.supportsAppleLog || caps.supportsProRes
                    ? Colors.amber.withValues(alpha: 0.45)
                    : Colors.white12,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.camera_rounded,
                  size: 18,
                  color: caps.supportsAppleLog || caps.supportsProRes
                      ? Colors.amber
                      : Colors.white38,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        caps.deviceName.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        caps.supportsProRes
                            ? 'ProRes 422 didukung. Master .mov 10-bit '
                                'direkam tanpa LUT agar tetap fleksibel saat '
                                'grading.'
                            : 'ProRes 422 tidak didukung perangkat ini (butuh '
                                'iPhone 13 Pro atau lebih baru).',
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
          if (caps.supportsProRes) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SwitchListTile(
                activeThumbColor: Colors.amber,
                title: const Text(
                  'ProRes 422',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: Text(
                  state.proResEnabled
                      ? 'Rekaman memakai 10-bit 4:2:2 ke .mov. LUT hanya '
                          'tampil di pratinjau, tidak dibakar ke file.'
                      : 'Master 10-bit untuk grading serius. Sensor dipindah '
                          'ke format 4:2:2 hanya selama merekam.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value: state.proResEnabled,
                onChanged: isRecording
                    ? null
                    : (value) {
                        tap();
                        notifier.setProResEnabled(value);
                      },
              ),
            ),
          ],
          if (caps.supportsAppleLog) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E22),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SwitchListTile(
                activeThumbColor: Colors.amber,
                title: const Text(
                  'Apple Log',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                subtitle: Text(
                  state.appleLogEnabled
                      ? 'Sensor mengirim Log datar. Grading tone/LUT dipakai '
                          'untuk melihat hasil akhir.'
                      : 'Gamma Log 10-bit sebelum grading, untuk highlight '
                          'yang tidak mudah pecah.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value: state.appleLogEnabled,
                onChanged: isRecording
                    ? null
                    : (value) {
                        tap();
                        notifier.setAppleLog(value);
                      },
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 16,
                    color: Colors.white38,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Apple Log tidak tersedia di ${caps.deviceName}. Gamma '
                      'Log 10-bit butuh chip A17 Pro atau lebih baru '
                      '(iPhone 15 Pro ke atas) — batas ini ada di hardware, '
                      'bukan di aplikasi. Jalur kualitas terbaik di perangkat '
                      'ini: aktifkan ProRes 422 untuk master 10-bit.',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E22),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  activeThumbColor: Colors.amber,
                  title: Text(
                    'Exposure · ${state.manualExposureEnabled ? 'MANUAL' : 'AUTO'}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    state.manualExposureEnabled
                        ? 'Shutter ${state.shutterLabel} · ISO '
                            '${state.iso.round()} terkunci di sensor.'
                        : 'iOS memilih shutter dan ISO otomatis.',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  value: state.manualExposureEnabled,
                  onChanged: (value) {
                    tap();
                    notifier.setManualExposureEnabled(value);
                  },
                ),
                _ProSlider(
                  label: 'SHUTTER',
                  value: state.shutterLabel,
                  sliderValue: _logToSlider(
                    state.shutterSeconds,
                    caps.minShutterSeconds,
                    caps.maxShutterSeconds,
                  ),
                  onChanged: (t) => notifier.previewManualExposure(
                    shutterSeconds: _logFromSlider(
                      t,
                      caps.minShutterSeconds,
                      caps.maxShutterSeconds,
                    ),
                  ),
                  onChangeEnd: (_) => notifier.commitManualExposure(),
                ),
                _ProSlider(
                  label: 'ISO',
                  value: state.iso.round().toString(),
                  sliderValue: _logToSlider(
                    state.iso,
                    caps.minIso,
                    caps.maxIso,
                  ),
                  onChanged: (t) => notifier.previewManualExposure(
                    iso: _logFromSlider(t, caps.minIso, caps.maxIso),
                  ),
                  onChangeEnd: (_) => notifier.commitManualExposure(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: state.is180ShutterLocked
                            ? Colors.black
                            : Colors.amber,
                        backgroundColor: state.is180ShutterLocked
                            ? Colors.amber
                            : Colors.transparent,
                        side: const BorderSide(color: Colors.amber),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: () {
                        tap();
                        notifier.toggle180DegreeShutter();
                      },
                      icon: const Icon(Icons.shutter_speed_rounded, size: 16),
                      label: Text(
                        state.is180ShutterLocked
                            ? '180° SHUTTER TERKUNCI (1/${state.frameRate.value * 2}s)'
                            : 'KUNCI 180° SHUTTER RULE (1/${state.frameRate.value * 2}s @ ${state.frameRate.value}FPS)',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),
                SwitchListTile(
                  activeThumbColor: Colors.amber,
                  title: Text(
                    'White Balance · '
                    '${state.manualWhiteBalanceEnabled ? 'MANUAL' : 'AUTO'}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    state.manualWhiteBalanceEnabled
                        ? '${state.whiteBalanceKelvin} K · tint '
                            '${state.whiteBalanceTint} terkunci.'
                        : 'iOS mengikuti warna cahaya sekitar.',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  value: state.manualWhiteBalanceEnabled,
                  onChanged: (value) {
                    tap();
                    notifier.setManualWhiteBalanceEnabled(value);
                  },
                ),
                _ProSlider(
                  label: 'SUHU',
                  value: '${state.whiteBalanceKelvin} K',
                  sliderValue: (state.whiteBalanceKelvin - 1000) / 13000,
                  onChanged: (t) => notifier.previewManualWhiteBalance(
                    kelvin: (1000 + t * 13000).round(),
                  ),
                  onChangeEnd: (_) => notifier.commitManualWhiteBalance(),
                ),
                _ProSlider(
                  label: 'TINT',
                  value: '${state.whiteBalanceTint}',
                  sliderValue: (state.whiteBalanceTint + 150) / 300,
                  onChanged: (t) => notifier.previewManualWhiteBalance(
                    tint: (t * 300 - 150).round(),
                  ),
                  onChangeEnd: (_) => notifier.commitManualWhiteBalance(),
                ),
                const Divider(height: 1, color: Colors.white12),
                SwitchListTile(
                  activeThumbColor: Colors.amber,
                  title: Text(
                    'Focus · ${state.manualFocusEnabled ? 'MANUAL' : 'AUTO'}',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    state.manualFocusEnabled
                        ? 'Posisi lensa ${(state.focusPosition * 100).round()}% '
                            '(0% jauh, 100% dekat).'
                        : 'Ketuk pratinjau atau pakai slider untuk fokus manual.',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  value: state.manualFocusEnabled,
                  onChanged: (value) {
                    tap();
                    notifier.setManualFocusEnabled(value);
                  },
                ),
                _ProSlider(
                  label: 'FOKUS',
                  value: '${(state.focusPosition * 100).round()}%',
                  sliderValue: state.focusPosition,
                  onChanged: notifier.previewManualFocus,
                ),
              ],
            ),
          ),
        ],
        if (state.proControlError != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF3A1B1B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.redAccent.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: Colors.redAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.proControlError!,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Slider positions travel on a log scale, matching how photographers think
  /// about shutter speed and ISO (each stop doubles the light).
  double _logToSlider(double value, double min, double max) {
    if (min <= 0 || max <= 0 || max <= min) return 0;
    final clamped = value.clamp(min, max).toDouble();
    return (math.log(clamped) - math.log(min)) /
        (math.log(max) - math.log(min));
  }

  double _logFromSlider(double t, double min, double max) {
    if (min <= 0 || max <= 0 || max <= min) return min;
    return math.exp(
        math.log(min) + t.clamp(0.0, 1.0) * (math.log(max) - math.log(min)));
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

/// One labelled slider row in the manual control panel.
class _ProSlider extends StatelessWidget {
  final String label;
  final String value;
  final double sliderValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  const _ProSlider({
    required this.label,
    required this.value,
    required this.sliderValue,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: sliderValue.clamp(0.0, 1.0),
              activeColor: Colors.amber,
              inactiveColor: Colors.white24,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/routing/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/cinema_tone.dart';
import '../providers/cinema_camera_provider.dart';
import '../providers/cinema_camera_state.dart';
import '../widgets/cinema_viewfinder_overlay.dart';
import '../widgets/custom_tone_editor_sheet.dart';
import '../widgets/preset_library_io_sheet.dart';
import '../widgets/tone_selector_strip.dart';

class CameraScreen extends ConsumerWidget {
  const CameraScreen({super.key});

  Future<void> _confirmDeleteCustomTone(
    BuildContext context,
    WidgetRef ref,
    CinemaTone tone,
  ) async {
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Hapus Preset "${tone.name}"?'),
        content: const Text('Preset warna kustom ini akan dihapus permanen.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(cinemaCameraProvider.notifier).deleteCustomTone(tone.id);
            },
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
  }

  void _openPresetLibrarySheet(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const PresetLibraryIoSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameraAsync = ref.watch(cinemaCameraProvider);
    final notifier = ref.read(cinemaCameraProvider.notifier);

    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      body: SafeArea(
        child: cameraAsync.when(
          loading: () => const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CupertinoActivityIndicator(radius: 14, color: AppTheme.cinemaAmber),
                SizedBox(height: 14),
                Text(
                  'Menyiapkan Lensa Sinematik 24fps...',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.camera_fill,
                    size: 48,
                    color: AppTheme.cinemaAmber,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Akses Kamera & Mikrofon Diperlukan\n$error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                  ),
                  const SizedBox(height: 20),
                  CupertinoButton.filled(
                    onPressed: () => ref.invalidate(cinemaCameraProvider),
                    child: const Text('Coba Lagi'),
                  ),
                ],
              ),
            ),
          ),
          data: (camState) {
            final controller = notifier.controller;
            if (controller == null || !controller.value.isInitialized) {
              return const Center(child: CupertinoActivityIndicator());
            }

            final flashIcon = switch (camState.flashMode) {
              FlashMode.off => CupertinoIcons.bolt_slash_fill,
              FlashMode.auto => CupertinoIcons.bolt_badge_a_fill,
              _ => CupertinoIcons.bolt_fill,
            };

            final isVideoMode =
                camState.captureMode == CinemaCaptureMode.video24fps;
            final isBusy = camState.isCapturing || camState.isProcessingVideo;

            return Stack(
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            onPressed: notifier.cycleFlashMode,
                            icon: Icon(
                              flashIcon,
                              color: camState.flashMode == FlashMode.off
                                  ? Colors.white70
                                  : AppTheme.cinemaAmber,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              HapticFeedback.lightImpact();
                              notifier.toggleAnamorphicRatio();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: camState.isAnamorphicRatio
                                    ? AppTheme.cinemaAmber
                                    : AppTheme.surfaceDark,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                camState.isAnamorphicRatio
                                    ? '2.39:1 SCOPE'
                                    : '16:9 / 4:3 FULL',
                                style: TextStyle(
                                  color: camState.isAnamorphicRatio
                                      ? Colors.black
                                      : Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Export / Import Preset JSON',
                                onPressed: camState.isRecordingVideo
                                    ? null
                                    : () => _openPresetLibrarySheet(context),
                                icon: const Icon(
                                  CupertinoIcons.arrow_up_arrow_down_square,
                                  color: AppTheme.cinemaAmber,
                                ),
                              ),
                              IconButton(
                                onPressed: notifier.toggleGrid,
                                icon: Icon(
                                  CupertinoIcons.grid,
                                  color: camState.showGrid
                                      ? AppTheme.cinemaAmber
                                      : Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return GestureDetector(
                              onTapDown: (details) {
                                final localPos = details.localPosition;
                                final normalized = Offset(
                                  (localPos.dx / constraints.maxWidth)
                                      .clamp(0.0, 1.0),
                                  (localPos.dy / constraints.maxHeight)
                                      .clamp(0.0, 1.0),
                                );
                                notifier.setFocusPoint(normalized, localPos);
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  ColorFiltered(
                                    colorFilter: ColorFilter.matrix(
                                      camState.activeColorMatrix,
                                    ),
                                    child: FittedBox(
                                      fit: BoxFit.cover,
                                      child: SizedBox(
                                        width: constraints.maxWidth,
                                        height: constraints.maxWidth *
                                            controller.value.aspectRatio,
                                        child: CameraPreview(controller),
                                      ),
                                    ),
                                  ),
                                  CinemaViewfinderOverlay(
                                    isAnamorphicRatio:
                                        camState.isAnamorphicRatio,
                                    showGrid: camState.showGrid,
                                    isVideoMode: isVideoMode,
                                    isRecordingVideo: camState.isRecordingVideo,
                                    recordingDuration:
                                        camState.recordingDuration,
                                    focusPoint: camState.focusPoint,
                                    activeToneName:
                                        camState.liveDraftParameters != null
                                            ? 'CUSTOM DRAFT'
                                            : camState.selectedTone.name,
                                    filmReference:
                                        camState.liveDraftParameters != null
                                            ? 'Live Grading'
                                            : camState
                                                .selectedTone.filmReference,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.film,
                            size: 15,
                            color: AppTheme.cinemaAmber,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'LUT ${(camState.intensity * 100).round()}%',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Expanded(
                            child: CupertinoSlider(
                              value: camState.intensity,
                              activeColor: AppTheme.cinemaAmber,
                              onChanged: notifier.setIntensity,
                            ),
                          ),
                          const Icon(
                            CupertinoIcons.sun_max_fill,
                            size: 15,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${camState.exposureOffset >= 0 ? '+' : ''}${camState.exposureOffset.toStringAsFixed(1)}',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: CupertinoSlider(
                              value: camState.exposureOffset,
                              min: camState.minExposure,
                              max: camState.maxExposure,
                              activeColor: Colors.white,
                              onChanged: notifier.setExposureOffset,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 4),

                    ToneSelectorStrip(
                      tones: camState.tones,
                      selectedTone: camState.selectedTone,
                      onToneSelected: notifier.selectTone,
                      onOpenCustomCreator: () {
                        showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          barrierColor: Colors.black.withValues(alpha: 0.25),
                          backgroundColor: Colors.transparent,
                          builder: (_) => const CustomToneEditorSheet(),
                        ).whenComplete(() {
                          notifier.updateLiveCustomDraft(null);
                        });
                      },
                      onDeleteCustomTone: (tone) =>
                          _confirmDeleteCustomTone(context, ref, tone),
                    ),

                    const SizedBox(height: 10),

                    CupertinoSlidingSegmentedControl<CinemaCaptureMode>(
                      groupValue: camState.captureMode,
                      backgroundColor: AppTheme.surfaceDark,
                      thumbColor: AppTheme.cinemaAmber,
                      onValueChanged: (mode) {
                        if (mode != null && !camState.isRecordingVideo) {
                          HapticFeedback.selectionClick();
                          notifier.setCaptureMode(mode);
                        }
                      },
                      children: {
                        CinemaCaptureMode.photo: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          child: Text(
                            'PHOTO',
                            style: TextStyle(
                              color: camState.captureMode ==
                                      CinemaCaptureMode.photo
                                  ? Colors.black
                                  : Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                        CinemaCaptureMode.video24fps: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          child: Text(
                            'VIDEO 24FPS',
                            style: TextStyle(
                              color: camState.captureMode ==
                                      CinemaCaptureMode.video24fps
                                  ? Colors.black
                                  : Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      },
                    ),

                    const SizedBox(height: 12),

                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: 12,
                        left: 32,
                        right: 32,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          SizedBox(
                            width: 48,
                            child: IconButton(
                              onPressed: () {
                                final activeTone = camState.selectedTone;
                                showCupertinoModalPopup<void>(
                                  context: context,
                                  builder: (ctx) => CupertinoActionSheet(
                                    title: Text(activeTone.name),
                                    message: Text(
                                      '${activeTone.filmReference}\n\n${activeTone.description}',
                                    ),
                                    actions: [
                                      CupertinoActionSheetAction(
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          notifier.exportSingleTone(activeTone);
                                        },
                                        child: const Text(
                                          'Bagikan Preset Ini (.json)',
                                        ),
                                      ),
                                      CupertinoActionSheetAction(
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          _openPresetLibrarySheet(context);
                                        },
                                        child: const Text(
                                          'Kelola Export / Import Preset',
                                        ),
                                      ),
                                    ],
                                    cancelButton: CupertinoActionSheetAction(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text('Tutup'),
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(
                                CupertinoIcons.info_circle,
                                color: Colors.white70,
                                size: 26,
                              ),
                            ),
                          ),

                          GestureDetector(
                            onTap: isBusy
                                ? null
                                : () async {
                                    HapticFeedback.heavyImpact();
                                    try {
                                      if (!isVideoMode) {
                                        final bytes =
                                            await notifier.captureAndSavePhoto();
                                        if (bytes != null && context.mounted) {
                                          context.push(
                                            '/preview',
                                            extra: CapturedPreviewArgs.photo(
                                              imageBytes: bytes,
                                              tone: camState.selectedTone,
                                              intensity: camState.intensity,
                                              isAnamorphic:
                                                  camState.isAnamorphicRatio,
                                            ),
                                          );
                                        }
                                      } else if (!camState.isRecordingVideo) {
                                        await notifier
                                            .startVideo24fpsRecording();
                                      } else {
                                        final videoPath = await notifier
                                            .stopVideo24fpsRecording();
                                        if (videoPath != null &&
                                            context.mounted) {
                                          context.push(
                                            '/preview',
                                            extra: CapturedPreviewArgs.video(
                                              videoFilePath: videoPath,
                                              tone: camState.selectedTone,
                                              intensity: camState.intensity,
                                              isAnamorphic:
                                                  camState.isAnamorphicRatio,
                                            ),
                                          );
                                        }
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text('Operasi gagal: $e'),
                                          ),
                                        );
                                      }
                                    }
                                  },
                            child: Container(
                              width: 74,
                              height: 74,
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isVideoMode
                                      ? const Color(0xFFFF3B30)
                                      : AppTheme.cinemaAmber,
                                  width: 3,
                                ),
                              ),
                              child: Center(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: camState.isRecordingVideo ? 28 : 60,
                                  height: camState.isRecordingVideo ? 28 : 60,
                                  decoration: BoxDecoration(
                                    color: isVideoMode
                                        ? const Color(0xFFFF3B30)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(
                                      camState.isRecordingVideo ? 6 : 30,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          SizedBox(
                            width: 48,
                            child: IconButton(
                              onPressed: camState.isRecordingVideo
                                  ? null
                                  : () {
                                      HapticFeedback.mediumImpact();
                                      notifier.switchCamera();
                                    },
                              icon: Icon(
                                CupertinoIcons.arrow_2_circlepath,
                                color: camState.isRecordingVideo
                                    ? Colors.white24
                                    : Colors.white,
                                size: 26,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                if (camState.isProcessingVideo)
                  Container(
                    color: Colors.black.withValues(alpha: 0.78),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CupertinoActivityIndicator(
                            radius: 16,
                            color: AppTheme.cinemaAmber,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Merender Video Sinematik 24fps...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Menyematkan tone warna & menyimpan ke Apple Photos',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

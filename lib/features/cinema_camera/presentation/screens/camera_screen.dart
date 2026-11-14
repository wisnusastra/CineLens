// lib/features/cinema_camera/presentation/screens/camera_screen.dart

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../../options/domain/entities/camera_options_state.dart';
import '../../../options/presentation/providers/camera_options_provider.dart';
import '../../../options/presentation/widgets/camera_options_sheet.dart';
import '../../../options/presentation/widgets/cinematic_viewfinder_overlay.dart';
import '../providers/cinema_camera_provider.dart';
import '../providers/cinema_camera_state.dart';
import '../widgets/custom_tone_editor_sheet.dart';
import '../widgets/preset_library_io_sheet.dart';
import '../widgets/tone_selector_strip.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  bool _isCapturingPhoto = false;
  bool _isTogglingVideo = false;

  CinemaCameraNotifier get _notifier =>
      ref.read(cinemaCameraProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(cinemaCameraProvider);
    final options = ref.watch(cameraOptionsProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: asyncState.when(
        loading: () => const _CinemaLoadingView(),
        error: (error, _) => _CinemaErrorView(
          message: _describe(error),
          onRetry: () => ref.invalidate(cinemaCameraProvider),
        ),
        data: (state) => _buildCameraStack(state, options),
      ),
    );
  }

  // ---------------------------------------------------------------- layout

  Widget _buildCameraStack(CinemaCameraState state, CameraOptionsState options) {
    final controller = _notifier.controller;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        return Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null && controller.value.isInitialized)
              _buildViewport(
                controller: controller,
                state: state,
                viewport: size,
                haptics: options.hapticFeedback,
                isLandscape: isLandscape,
              )
            else
              const _CinemaLoadingView(),

            // Grid / aspect-ratio / HUD overlay
            CinematicViewfinderOverlay(
              activeToneName: state.selectedTone.name,
            ),

            if (state.focusPoint != null)
              Positioned(
                left: state.focusPoint!.dx - 32,
                top: state.focusPoint!.dy - 32,
                child: IgnorePointer(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppTheme.cinemaAmber, width: 1.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),

            if (state.isRecordingVideo) _buildRecordingBadge(state),

            _buildTopLeftActions(state),
            _buildTopRightActions(state),

            if (state.isProcessingVideo) _buildProcessingOverlay(),

            Align(
              alignment: Alignment.bottomCenter,
              child: _buildControls(state, options.hapticFeedback, isLandscape),
            ),
          ],
        );
      },
    );
  }

  Widget _buildViewport({
    required CameraController controller,
    required CinemaCameraState state,
    required Size viewport,
    required bool haptics,
    required bool isLandscape,
  }) {
    final previewSize = controller.value.previewSize ?? const Size(1920, 1080);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => _handleFocusTap(details, viewport, haptics),
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(state.activeColorMatrix),
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: isLandscape ? previewSize.width : previewSize.height,
              height: isLandscape ? previewSize.height : previewSize.width,
              child: CameraPreview(controller),
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- controls

  Widget _buildControls(
    CinemaCameraState state,
    bool haptics,
    bool isLandscape,
  ) {
    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(12, 14, 12, isLandscape ? 10 : 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.92),
              Colors.black.withValues(alpha: 0.45),
              Colors.transparent,
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ToneSelectorStrip(
              tones: state.tones,
              selectedTone: state.selectedTone,
              onToneSelected: _notifier.selectTone,
              onOpenCustomCreator: _openCustomToneEditor,
              onDeleteCustomTone: _confirmDeleteTone,
            ),
            const SizedBox(height: 6),
            _buildIntensityRow(state),
            const SizedBox(height: 4),
            _buildShutterRow(state, haptics),
          ],
        ),
      ),
    );
  }

  Widget _buildIntensityRow(CinemaCameraState state) {
    return Row(
      children: [
        const Icon(
          CupertinoIcons.slider_horizontal_3,
          color: AppTheme.textSecondary,
          size: 16,
        ),
        Expanded(
          child: SizedBox(
            height: 26,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: AppTheme.cinemaAmber,
                inactiveTrackColor: Colors.white24,
                thumbColor: AppTheme.cinemaAmber,
                overlayColor: AppTheme.cinemaAmber.withValues(alpha: 0.2),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: state.intensity.clamp(0.0, 1.0),
                onChanged: _notifier.setIntensity,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(state.intensity * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShutterRow(CinemaCameraState state, bool haptics) {
    return Row(
      children: [
        SizedBox(width: 92, child: _buildModeToggle(state)),
        const Spacer(),
        _buildShutterButton(state, haptics),
        const Spacer(),
        SizedBox(
          width: 92,
          child: Center(
            child: _circleButton(
              icon: Icons.cameraswitch_rounded,
              active: false,
              onTap: state.isRecordingVideo ? null : _switchCamera,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModeToggle(CinemaCameraState state) {
    final isVideo = state.captureMode == CinemaCaptureMode.video24fps;

    return GestureDetector(
      onTap: state.isRecordingVideo
          ? null
          : () => _notifier.setCaptureMode(
                isVideo
                    ? CinemaCaptureMode.photo
                    : CinemaCaptureMode.video24fps,
              ),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: isVideo
              ? Colors.redAccent.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isVideo ? Colors.redAccent : Colors.white24,
          ),
        ),
        child: Text(
          isVideo ? '24 FPS' : 'PHOTO',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isVideo ? Colors.redAccent : Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _buildShutterButton(CinemaCameraState state, bool haptics) {
    final isVideo = state.captureMode == CinemaCaptureMode.video24fps;
    final isBusy = state.isCapturing ||
        _isCapturingPhoto ||
        _isTogglingVideo ||
        state.isProcessingVideo;

    return GestureDetector(
      onTap: isBusy
          ? null
          : () => isVideo
              ? _handleVideoToggle(haptics)
              : _handlePhotoCapture(haptics),
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: isVideo ? Colors.redAccent : Colors.white,
            width: 4,
          ),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: state.isRecordingVideo ? 26 : 60,
            height: state.isRecordingVideo ? 26 : 60,
            decoration: BoxDecoration(
              color: isVideo ? Colors.redAccent : Colors.white,
              borderRadius:
                  BorderRadius.circular(state.isRecordingVideo ? 6 : 30),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopLeftActions(CinemaCameraState state) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _circleButton(
                icon: Icons.grid_3x3_rounded,
                active: state.showGrid,
                onTap: _notifier.toggleGrid,
              ),
              const SizedBox(width: 8),
              _circleButton(
                icon: Icons.crop_16_9_rounded,
                active: state.isAnamorphicRatio,
                onTap: state.isRecordingVideo
                    ? null
                    : _notifier.toggleAnamorphicRatio,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopRightActions(CinemaCameraState state) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _circleButton(
                icon: _flashIcon(state.flashMode),
                active: state.flashMode != FlashMode.off,
                onTap: _notifier.cycleFlashMode,
              ),
              const SizedBox(width: 8),
              _circleButton(
                icon: Icons.folder_open_rounded,
                active: false,
                onTap: _openPresetLibrary,
              ),
              const SizedBox(width: 8),
              const CameraOptionsButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingBadge(CinemaCameraState state) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fiber_manual_record, color: Colors.white, size: 12),
              const SizedBox(width: 6),
              Text(
                'REC ${_formatDuration(state.recordingDuration)}',
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
    );
  }

  Widget _buildProcessingOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: AppTheme.cinemaAmber),
              SizedBox(height: 14),
              Text(
                'Memproses video 24fps...',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required bool active,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(
            color: active ? AppTheme.cinemaAmber : Colors.white24,
          ),
        ),
        child: Icon(
          icon,
          size: 19,
          color: active ? AppTheme.cinemaAmber : Colors.white,
        ),
      ),
    );
  }

  // --------------------------------------------------------------- actions

  Future<void> _handleFocusTap(
    TapDownDetails details,
    Size viewport,
    bool haptics,
  ) async {
    if (viewport.isEmpty) return;
    if (haptics) HapticFeedback.selectionClick();

    final dx = (details.localPosition.dx / viewport.width).clamp(0.0, 1.0);
    final dy = (details.localPosition.dy / viewport.height).clamp(0.0, 1.0);

    await _notifier.setFocusPoint(Offset(dx, dy), details.localPosition);
  }

  Future<void> _handlePhotoCapture(bool haptics) async {
    if (_isCapturingPhoto) return;
    if (haptics) HapticFeedback.mediumImpact();

    setState(() => _isCapturingPhoto = true);
    try {
      final bytes = await _notifier.captureAndSavePhoto();
      if (!mounted || bytes == null) return;

      final state = ref.read(cinemaCameraProvider).valueOrNull;
      if (state == null) return;

      context.push(
        '/preview',
        extra: CapturedPreviewArgs.photo(
          imageBytes: bytes,
          tone: state.selectedTone,
          intensity: state.intensity,
          isAnamorphic: state.isAnamorphicRatio,
        ),
      );
    } catch (error) {
      _toast('Gagal memotret: ${_describe(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _isCapturingPhoto = false);
    }
  }

  Future<void> _handleVideoToggle(bool haptics) async {
    if (_isTogglingVideo) return;
    if (haptics) HapticFeedback.mediumImpact();

    final state = ref.read(cinemaCameraProvider).valueOrNull;
    if (state == null) return;

    setState(() => _isTogglingVideo = true);
    try {
      if (state.isRecordingVideo) {
        final path = await _notifier.stopVideo24fpsRecording();
        if (!mounted || path == null) return;

        context.push(
          '/preview',
          extra: CapturedPreviewArgs.video(
            videoFilePath: path,
            tone: state.selectedTone,
            intensity: state.intensity,
            isAnamorphic: state.isAnamorphicRatio,
          ),
        );
      } else {
        await _notifier.startVideo24fpsRecording();
      }
    } catch (error) {
      _toast('Gagal merekam video: ${_describe(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _isTogglingVideo = false);
    }
  }

  Future<void> _switchCamera() async {
    try {
      await _notifier.switchCamera();
    } catch (error) {
      _toast('Gagal mengganti kamera: ${_describe(error)}', isError: true);
    }
  }

  Future<void> _openCustomToneEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const CustomToneEditorSheet(),
    );
  }

  Future<void> _openPresetLibrary() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const PresetLibraryIoSheet(),
    );
  }

  Future<void> _confirmDeleteTone(CinemaTone tone) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text(
          'Hapus preset?',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Text(
          'Preset "${tone.name}" akan dihapus permanen dari perangkat ini.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Hapus', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _notifier.deleteCustomTone(tone.id);
      _toast('Preset "${tone.name}" dihapus.');
    } catch (error) {
      _toast('Gagal menghapus preset: ${_describe(error)}', isError: true);
    }
  }

  // --------------------------------------------------------------- helpers

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: isError ? const Color(0xFFB3261E) : AppTheme.surfaceDark,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _describe(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  IconData _flashIcon(FlashMode mode) => switch (mode) {
        FlashMode.off => Icons.flash_off_rounded,
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.always => Icons.flash_on_rounded,
        FlashMode.torch => Icons.highlight_rounded,
      };
}

// ------------------------------------------------------------------ states

class _CinemaLoadingView extends StatelessWidget {
  const _CinemaLoadingView();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppTheme.cinemaAmber),
            SizedBox(height: 16),
            Text(
              'Menyiapkan kamera sinematik...',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _CinemaErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _CinemaErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
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
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.cinemaAmber,
                  foregroundColor: Colors.black,
                ),
                onPressed: onRetry,
                child: const Text('Coba Lagi'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

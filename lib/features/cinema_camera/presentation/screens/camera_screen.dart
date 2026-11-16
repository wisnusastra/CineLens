// lib/features/cinema_camera/presentation/screens/camera_screen.dart

import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/film_look.dart';
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
  bool _orientationLocked = false;

  /// Landscape starts with the tone tray collapsed so the viewfinder stays
  /// visible; portrait keeps it open.
  bool _trayVisible = true;
  bool? _wasLandscape;

  bool _zoomIndicatorVisible = false;
  Timer? _zoomIndicatorTimer;
  double _scaleStartZoom = 1.0;
  bool _isSwitchingQuality = false;

  CinemaCameraNotifier get _notifier => ref.read(cinemaCameraProvider.notifier);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (_wasLandscape != isLandscape) {
      _wasLandscape = isLandscape;
      _trayVisible = !isLandscape;
      if (isLandscape) _zoomIndicatorVisible = false;
    }
  }

  @override
  void dispose() {
    _zoomIndicatorTimer?.cancel();
    if (_orientationLocked) {
      // Never leave the rest of the app stuck in the recording orientation.
      SystemChrome.setPreferredOrientations(
        AppConstants.supportedOrientations,
      );
    }
    super.dispose();
  }

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

  Widget _buildCameraStack(
      CinemaCameraState state, CameraOptionsState options) {
    final controller = _notifier.controller;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

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
                      border:
                          Border.all(color: AppTheme.cinemaAmber, width: 1.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),

            if (state.isRecordingVideo) _buildRecordingBadge(state),

            _buildTopLeftActions(state),
            _buildTopRightActions(state),

            if (state.isZoomed || _zoomIndicatorVisible)
              Positioned(
                left: 0,
                right: 0,
                bottom: isLandscape ? 138 : 214,
                child: Center(child: _buildZoomIndicator(state)),
              ),

            if (state.isProcessingVideo) _buildProcessingOverlay(),

            Align(
              alignment: Alignment.bottomCenter,
              child: _buildControls(state, options, isLandscape),
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
      onTapUp: (details) => _handleFocusTap(
        details.localPosition,
        viewport,
        haptics,
      ),
      onScaleStart: (_) {
        _scaleStartZoom = state.zoomLevel;
      },
      onScaleUpdate: (details) {
        if (details.pointerCount < 2) return;
        _flashZoomIndicator();
        _notifier.setZoomLevel(_scaleStartZoom * details.scale);
      },
      onScaleEnd: (_) {
        if (!_zoomIndicatorVisible) return;
        _zoomIndicatorTimer?.cancel();
        _zoomIndicatorTimer = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _zoomIndicatorVisible = false);
        });
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColorFiltered(
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
          if (!state.filmLook.isNeutral)
            IgnorePointer(
              child: _FilmPreviewOverlay(look: state.filmLook),
            ),
          if (state.isAnamorphicRatio)
            ..._buildAnamorphicGuide(
              previewSize: previewSize,
              viewport: viewport,
              isLandscape: isLandscape,
            ),
        ],
      ),
    );
  }

  /// Draws the 2.39:1 letterbox the exporter bakes into every capture.
  ///
  /// The preview is drawn with `BoxFit.cover`, so the bars are measured from
  /// the recorded frame instead of the screen: the visible frame can be taller
  /// than the viewport, and in that case part of the letterbox is already
  /// cropped away and must not be drawn.
  List<Widget> _buildAnamorphicGuide({
    required Size previewSize,
    required Size viewport,
    required bool isLandscape,
  }) {
    if (viewport.isEmpty) return const [];

    final frameWidth = isLandscape ? previewSize.width : previewSize.height;
    final frameHeight = isLandscape ? previewSize.height : previewSize.width;
    if (frameWidth <= 0 || frameHeight <= 0) return const [];

    final scale = math.max(
      viewport.width / frameWidth,
      viewport.height / frameHeight,
    );
    final visibleFrameHeight = frameHeight * scale;
    final letterboxHeight = (frameWidth / 2.39) * scale;
    final barHeight = ((visibleFrameHeight - letterboxHeight) / 2)
        .clamp(0.0, viewport.height);
    final topInset = (viewport.height - visibleFrameHeight) / 2;
    final visibleBarHeight = (topInset + barHeight).clamp(0.0, viewport.height);

    if (visibleBarHeight <= 0.5) return const [];

    final bar = ColoredBox(
      color: Colors.black.withValues(alpha: 0.62),
    );

    return [
      Positioned(
          top: 0, left: 0, right: 0, height: visibleBarHeight, child: bar),
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        height: visibleBarHeight,
        child: bar,
      ),
    ];
  }

  void _flashZoomIndicator() {
    _zoomIndicatorTimer?.cancel();
    if (!_zoomIndicatorVisible) {
      setState(() => _zoomIndicatorVisible = true);
    }
    _zoomIndicatorTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _zoomIndicatorVisible = false);
    });
  }

  Widget _buildZoomIndicator(CinemaCameraState state) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        _notifier.resetZoom();
        _flashZoomIndicator();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppTheme.cinemaAmber.withValues(alpha: 0.65),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.zoom_in_rounded,
              color: AppTheme.cinemaAmber,
              size: 14,
            ),
            const SizedBox(width: 6),
            Text(
              '${state.zoomLevel.toStringAsFixed(1)}×',
              style: const TextStyle(
                color: AppTheme.cinemaAmber,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'TAP RESET',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 8,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- controls

  Widget _buildControls(
    CinemaCameraState state,
    CameraOptionsState options,
    bool isLandscape,
  ) {
    final haptics = options.hapticFeedback;
    final showTray = !isLandscape || _trayVisible;

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          12,
          isLandscape ? 8 : 14,
          12,
          isLandscape ? 8 : 18,
        ),
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
            if (showTray) ...[
              if (isLandscape) _buildTrayHeader(state),
              ToneSelectorStrip(
                tones: state.tones,
                selectedTone: state.selectedTone,
                onToneSelected: _notifier.selectTone,
                onOpenCustomCreator: _openCustomToneEditor,
                onDeleteCustomTone: _confirmDeleteTone,
                compact: isLandscape,
              ),
              SizedBox(height: isLandscape ? 4 : 6),
              _buildIntensityRow(state),
              SizedBox(height: isLandscape ? 2 : 4),
            ],
            _buildShutterRow(state, haptics, isLandscape),
          ],
        ),
      ),
    );
  }

  /// Compact header shown only in landscape, so the tone tray can be tucked
  /// away without hunting for the button.
  Widget _buildTrayHeader(CinemaCameraState state) {
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 2, bottom: 4),
      child: Row(
        children: [
          const Text(
            'TONE PRESET',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              state.selectedTone.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.cinemaAmber,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _trayVisible = false);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'SEMBUNYIKAN',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: Colors.white70,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
        ],
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

  Widget _buildShutterRow(
    CinemaCameraState state,
    bool haptics,
    bool isLandscape,
  ) {
    return Row(
      children: [
        SizedBox(width: 92, child: _buildLeftSlot(state)),
        const Spacer(),
        _buildShutterButton(state, haptics),
        const Spacer(),
        SizedBox(
          width: isLandscape ? 132 : 92,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (isLandscape) ...[
                _circleButton(
                  icon: _trayVisible
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.palette_rounded,
                  active: _trayVisible,
                  onTap: () {
                    setState(() => _trayVisible = !_trayVisible);
                  },
                ),
                const SizedBox(width: 8),
              ],
              _circleButton(
                icon: Icons.cameraswitch_rounded,
                active: false,
                onTap: state.isRecordingVideo ? null : _switchCamera,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLeftSlot(CinemaCameraState state) {
    final isVideo = state.captureMode == CinemaCaptureMode.video24fps;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildModeToggle(state),
        const SizedBox(height: 4),
        _buildQualityChip(state),
        if (isVideo) ...[
          const SizedBox(height: 4),
          _buildStabilizationChip(state),
        ],
        if (state.isManualCaptureActive || state.proResEnabled) ...[
          const SizedBox(height: 4),
          _buildProChip(state),
        ],
      ],
    );
  }

  /// Compact readout of every subsystem the operator locked by hand, so it is
  /// obvious on set that exposure/white balance/focus are no longer automatic.
  Widget _buildProChip(CinemaCameraState state) {
    final parts = <String>[
      if (state.proResEnabled) 'PRORES',
      if (state.appleLogEnabled) 'LOG',
      if (state.manualExposureEnabled) state.exposureHudLabel,
      if (state.manualWhiteBalanceEnabled) state.whiteBalanceLabel,
      if (state.manualFocusEnabled) 'MF',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      decoration: BoxDecoration(
        color: AppTheme.cinemaAmber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.cinemaAmber.withValues(alpha: 0.65)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.tune_rounded,
            size: 9,
            color: AppTheme.cinemaAmber,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.cinemaAmber,
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shows the stabilisation mode iOS actually sustained for this format,
  /// so the operator knows when 4K forced it down to standard (or off).
  Widget _buildStabilizationChip(CinemaCameraState state) {
    final active = state.videoStabilizationActive;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      decoration: BoxDecoration(
        color: active
            ? AppTheme.cinemaAmber.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active
              ? AppTheme.cinemaAmber.withValues(alpha: 0.7)
              : Colors.white24,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.video_stable_rounded,
            size: 9,
            color: active ? AppTheme.cinemaAmber : Colors.white38,
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              'STAB ${state.stabilizationLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? AppTheme.cinemaAmber : Colors.white38,
                fontSize: 8,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityChip(CinemaCameraState state) {
    return GestureDetector(
      onTap: state.isRecordingVideo ? null : _openCameraOptions,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          state.qualityLabel,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  Widget _buildModeToggle(CinemaCameraState state) {
    final isVideo = state.captureMode == CinemaCaptureMode.video24fps;

    return GestureDetector(
      onTap: state.isRecordingVideo ? null : () => _handleModeToggle(state),
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
          isVideo ? 'VIDEO' : 'PHOTO',
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
                icon: Icons.photo_library_rounded,
                active: false,
                onTap: () => context.push('/gallery'),
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
              const Icon(Icons.fiber_manual_record,
                  color: Colors.white, size: 12),
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
    Offset localPosition,
    Size viewport,
    bool haptics,
  ) async {
    if (viewport.isEmpty) return;
    if (haptics) HapticFeedback.selectionClick();

    final dx = (localPosition.dx / viewport.width).clamp(0.0, 1.0);
    final dy = (localPosition.dy / viewport.height).clamp(0.0, 1.0);

    await _notifier.setFocusPoint(Offset(dx, dy), localPosition);
  }

  Future<void> _handleModeToggle(CinemaCameraState state) async {
    if (state.isRecordingVideo) return;
    final next = state.captureMode == CinemaCaptureMode.video24fps
        ? CinemaCaptureMode.photo
        : CinemaCaptureMode.video24fps;

    await _applyProfile(
      () => _notifier.setCaptureMode(next),
      'mode ${next == CinemaCaptureMode.photo ? "Photo" : "Video"}',
    );
  }

  /// Runs a capture-profile change (mode / resolution / fps) and reports a
  /// failure instead of leaving the viewfinder stuck on the loading view.
  Future<void> _applyProfile(
    Future<void> Function() action,
    String label,
  ) async {
    if (_isSwitchingQuality) return;
    setState(() => _isSwitchingQuality = true);
    try {
      await action();
    } catch (error) {
      _toast('Gagal mengganti $label: ${_describe(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _isSwitchingQuality = false);
    }
  }

  Future<void> _handlePhotoCapture(bool haptics) async {
    if (_isCapturingPhoto) return;
    if (haptics) HapticFeedback.mediumImpact();

    setState(() => _isCapturingPhoto = true);
    try {
      final result = await _notifier.captureAndSavePhoto();
      if (!mounted || result == null) return;

      if (result.warning != null) _toast(result.warning!);

      final state = ref.read(cinemaCameraProvider).valueOrNull;
      if (state == null) return;

      context.push(
        '/preview',
        extra: CapturedPreviewArgs.photo(
          imageBytes: result.bytes,
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

    final wasRecording = state.isRecordingVideo;
    setState(() => _isTogglingVideo = true);
    try {
      if (wasRecording) {
        final result = await _notifier.stopVideo24fpsRecording();
        await _unlockOrientation();
        if (!mounted) return;

        if (result == null) {
          _toast(
            'Rekaman tidak dapat disimpan. Silakan rekam ulang.',
            isError: true,
          );
          return;
        }
        if (result.warning != null) _toast(result.warning!);

        context.push(
          '/preview',
          extra: CapturedPreviewArgs.video(
            videoFilePath: result.path,
            tone: state.selectedTone,
            intensity: state.intensity,
            isAnamorphic: state.isAnamorphicRatio,
          ),
        );
      } else {
        await _lockOrientationForRecording();
        if (!mounted) return;
        await _notifier.startVideo24fpsRecording();
      }
    } catch (error) {
      await _unlockOrientation();
      _toast('Gagal merekam video: ${_describe(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _isTogglingVideo = false);
    }
  }

  /// Locks the UI to the orientation the phone is held in.
  ///
  /// The camera plugin samples the *physical* device orientation and cannot
  /// change it once recording started, so letting the UI keep rotating while
  /// filming is what produces a "upright frame with a tilted video". The
  /// plugin's own value is preferred over `MediaQuery.orientation` because the
  /// latter still reports the previous orientation right after a turn.
  Future<void> _lockOrientationForRecording() async {
    final deviceOrientation = _notifier.controller?.value.deviceOrientation;

    final bool lockLandscape;
    if (deviceOrientation == DeviceOrientation.landscapeLeft ||
        deviceOrientation == DeviceOrientation.landscapeRight) {
      lockLandscape = true;
    } else if (deviceOrientation == DeviceOrientation.portraitUp ||
        deviceOrientation == DeviceOrientation.portraitDown) {
      lockLandscape = false;
    } else {
      lockLandscape =
          MediaQuery.of(context).orientation == Orientation.landscape;
    }

    _orientationLocked = true;
    await SystemChrome.setPreferredOrientations(
      lockLandscape ? AppConstants.landscapeOnly : AppConstants.portraitOnly,
    );
  }

  Future<void> _unlockOrientation() async {
    if (!_orientationLocked) return;
    _orientationLocked = false;
    await SystemChrome.setPreferredOrientations(
      AppConstants.supportedOrientations,
    );
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

  Future<void> _openCameraOptions() async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141416),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => const CameraOptionsSheet(),
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
            child:
                const Text('Hapus', style: TextStyle(color: Colors.redAccent)),
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
        backgroundColor:
            isError ? const Color(0xFFB3261E) : AppTheme.surfaceDark,
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

/// Lightweight approximation of the film look for the live viewfinder.
///
/// Flutter can draw but not run Core Image, so only the two effects that read
/// well as an overlay are shown here: fine luminance grain and the vignette.
/// Halation and bloom need a real blur pass over the highlights, so the native
/// pipeline bakes them into the saved photo/video instead.
class _FilmPreviewOverlay extends StatelessWidget {
  final FilmLook look;

  const _FilmPreviewOverlay({required this.look});

  @override
  Widget build(BuildContext context) {
    final grain = look.grain.clamp(0.0, 1.0);
    final vignette = look.vignette.clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        if (grain > 0.01)
          RepaintBoundary(
            child: CustomPaint(
              painter: _GrainPainter(
                strength: grain,
                size: look.grainSize,
              ),
            ),
          ),
        if (vignette > 0.01)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.95,
                stops: const [0.55, 1.0],
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: vignette * 0.55),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Draws a static field of 1–2 px specks, which is what gives the preview its
/// film texture without repainting every frame.
class _GrainPainter extends CustomPainter {
  final double strength;
  final double size;

  const _GrainPainter({required this.strength, required this.size});

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (canvasSize.isEmpty) return;

    final dot = 1.0 + size.clamp(0.0, 1.0) * 1.2;
    final count = ((canvasSize.width * canvasSize.height) / 260)
        .clamp(400.0, 2800.0)
        .round();
    final random = math.Random(20240517);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < count; i++) {
      final x = random.nextDouble() * canvasSize.width;
      final y = random.nextDouble() * canvasSize.height;
      // Alternating light and dark specks keep the average exposure neutral.
      final light = random.nextBool();
      final alpha = light ? 0.02 + strength * 0.10 : 0.02 + strength * 0.07;
      paint.color = (light ? Colors.white : Colors.black)
          .withValues(alpha: alpha.clamp(0.0, 0.35));
      canvas.drawRect(Rect.fromLTWH(x, y, dot, dot), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GrainPainter oldDelegate) =>
      oldDelegate.strength != strength || oldDelegate.size != size;
}

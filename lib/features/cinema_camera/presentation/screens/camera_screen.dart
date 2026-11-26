// lib/features/cinema_camera/presentation/screens/camera_screen.dart

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/l10n/app_strings.dart';
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
import '../widgets/dop_overlays.dart';
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
  bool _trayVisible = true;
  bool? _wasLandscape;

  bool _zoomIndicatorVisible = false;
  Timer? _zoomIndicatorTimer;
  double _scaleStartZoom = 1.0;
  bool _isSwitchingQuality = false;

  int _countdownRemaining = 0;
  Timer? _countdownTimer;
  bool _apertureSliderExpanded = false;

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
    _countdownTimer?.cancel();
    if (_orientationLocked) {
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

    ref.listen<AsyncValue<CinemaCameraState>>(cinemaCameraProvider,
        (prev, next) {
      final prevTick = prev?.valueOrNull?.hardwareShutterTick ?? 0;
      final nextState = next.valueOrNull;
      if (nextState == null || nextState.hardwareShutterTick == prevTick) {
        return;
      }
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final isVideo = nextState.captureMode.isVideo;
      if (isVideo) {
        _handleVideoToggle(options.hapticFeedback);
      } else {
        _triggerPhotoWithTimer(options.hapticFeedback);
      }
    });

    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      body: asyncState.when(
        loading: () => const _CinemaLoadingView(),
        error: (error, _) => _CinemaErrorView(
          message: _describe(error),
          onRetry: () => ref.invalidate(cinemaCameraProvider),
        ),
        data: (state) => _buildProLayout(state, options),
      ),
    );
  }

  // ------------------------------------------------------------------ layout

  Widget _buildProLayout(CinemaCameraState state, CameraOptionsState options) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape) {
      return _buildLandscapeStack(state, options);
    }

    return Column(
      children: [
        // 1. Top Precision Telemetry Strip (Blackmagic / Leica style)
        _buildTelemetryStrip(state, options.hapticFeedback),
        // 2. Unobstructed Viewfinder with Vintage Frame Mask & DOP Overlays
        Expanded(
          child: ClipRect(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return _buildViewfinderStack(
                  state: state,
                  options: options,
                  viewport: size,
                  isLandscape: false,
                );
              },
            ),
          ),
        ),
        // 3. Bottom Tactile Precision Deck
        _buildBottomDeck(state, options, isLandscape: false),
      ],
    );
  }

  Widget _buildLandscapeStack(
    CinemaCameraState state,
    CameraOptionsState options,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            _buildViewfinderStack(
              state: state,
              options: options,
              viewport: size,
              isLandscape: true,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildTelemetryStrip(state, options.hapticFeedback,
                  translucent: true),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _buildBottomDeck(state, options, isLandscape: true),
            ),
          ],
        );
      },
    );
  }

  // --------------------------------------------------------- top telemetry

  Widget _buildTelemetryStrip(
    CinemaCameraState state,
    bool haptics, {
    bool translucent = false,
  }) {
    final s = AppStrings.of(context);
    final isVideo = state.captureMode.isVideo;
    final resText = isVideo
        ? '${state.resolution.isMaxSensor ? '4K' : state.resolution.label}·${state.frameRate.label}'
        : (state.hiRes48MP ? '48MP' : state.resolution.label);
    final shutterText =
        state.manualExposureEnabled ? state.shutterLabel : 'AUTO';
    final isoText =
        state.manualExposureEnabled ? '${state.iso.round()}' : 'AUTO';
    final wbText =
        state.manualWhiteBalanceEnabled ? '${state.whiteBalanceKelvin}K' : 'AUTO';
    final frameText = state.frameFormat.label;

    return Container(
      decoration: BoxDecoration(
        color: translucent
            ? Colors.black.withValues(alpha: 0.62)
            : AppTheme.backgroundBlack,
        border: const Border(
          bottom: BorderSide(color: AppTheme.hairline, width: 0.7),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 46,
          child: Row(
            children: [
              _TelemetryCell(
                label: s.resFps,
                value: resText,
                accent: state.proResEnabled || state.directLutRecordingEnabled,
                onTap: () => _openDrawer(3, haptics),
              ),
              _TelemetryDivider(),
              _TelemetryCell(
                label: s.shutter,
                value: shutterText,
                accent: state.manualExposureEnabled,
                onTap: () => _openDrawer(0, haptics),
              ),
              _TelemetryDivider(),
              _TelemetryCell(
                label: s.iso,
                value: isoText,
                accent: state.manualExposureEnabled,
                onTap: () => _openDrawer(0, haptics),
              ),
              _TelemetryDivider(),
              _TelemetryCell(
                label: s.wb,
                value: wbText,
                accent: state.manualWhiteBalanceEnabled,
                onTap: () => _openDrawer(0, haptics),
              ),
              _TelemetryDivider(),
              _TelemetryCell(
                label: s.frameFormat.split(' ').first,
                value: frameText,
                accent: state.effectiveFrameAspectRatio > 0.1,
                onTap: () => _openDrawer(2, haptics),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- viewfinder

  Widget _buildViewfinderStack({
    required CinemaCameraState state,
    required CameraOptionsState options,
    required Size viewport,
    required bool isLandscape,
  }) {
    final isVideo = state.captureMode.isVideo;
    final hasLiveMetal = state.isGpuGradingActive;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (state.liveMetalTextureId != null)
          _buildInteractiveFeed(
            state: state,
            viewport: viewport,
            haptics: options.hapticFeedback,
            isLandscape: isLandscape,
            hasLiveMetal: hasLiveMetal,
          )
        else
          const _CinemaLoadingView(),

        // Composition grid
        CinematicViewfinderOverlay(
          activeToneName: state.selectedTone.name,
          showGrid: state.showGrid,
        ),

        // Dynamic Vintage & Cinema Frame Mask (1:1, 4:5, 6:7, 3:2, 16:9, 2.39, XPan)
        if (state.effectiveFrameAspectRatio > 0.1)
          IgnorePointer(
            child: _FrameAspectMask(
              aspectRatio: state.effectiveFrameAspectRatio,
              isLandscape: isLandscape,
            ),
          ),

        // Tahap 2 Horizon Level Overlay
        if (state.horizonLevelEnabled)
          HorizonLevelOverlay(degrees: state.horizonDegrees),

        // Tap-to-focus reticle
        if (state.focusPoint != null)
          Positioned(
            left: state.focusPoint!.dx - 30,
            top: state.focusPoint!.dy - 30,
            child: IgnorePointer(
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.cinemaAmber, width: 1.4),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),

        // Top-left active DOP monitors (Live Scope + micro status chips)
        Positioned(
          top: isLandscape ? 54 : 10,
          left: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.liveScopeEnabled) ...[
                LiveCameraScopeMini(scopeData: state.liveScopeData),
                const SizedBox(height: 6),
              ],
              _buildActiveBadges(state, hasLiveMetal),
            ],
          ),
        ),

        // Top-center Recording timer or Audio dB Meter
        if (state.isRecordingVideo)
          Positioned(
            top: isLandscape ? 54 : 10,
            left: 0,
            right: 0,
            child: Center(child: _buildRecordingBadge(state)),
          )
        else if (isVideo && state.audioMeterEnabled)
          Positioned(
            top: isLandscape ? 54 : 10,
            right: 12,
            child: AudioMeterOverlay(peakDb: state.audioPeakDb),
          ),

        if (state.isRecordingVideo && state.audioMeterEnabled)
          Positioned(
            top: isLandscape ? 54 : 10,
            right: 12,
            child: AudioMeterOverlay(peakDb: state.audioPeakDb),
          ),

        // Zoom indicator pill
        if (state.isZoomed || _zoomIndicatorVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: state.captureMode.isBokehMode ? 96 : 48,
            child: Center(child: _buildZoomIndicator(state)),
          ),

        // Portrait / Cinematic Mode floating Aperture (f/1.4 – f/16) & Rack Focus bar
        if (state.captureMode.isBokehMode)
          Positioned(
            left: 14,
            right: 14,
            bottom: 48,
            child: _buildApertureBar(state, options.hapticFeedback),
          ),

        // Bottom-of-viewfinder clean Lens Switcher + Quick Tools
        Positioned(
          left: 12,
          right: 12,
          bottom: 10,
          child: _buildViewfinderBottomRow(state, options.hapticFeedback),
        ),

        // Self-Timer countdown overlay
        if (_countdownRemaining > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.25),
                child: Center(
                  child: Text(
                    '$_countdownRemaining',
                    style: AppTheme.monoStyle(
                      color: AppTheme.cinemaAmber,
                      fontSize: 84,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),

        // Processing overlay
        if (state.isProcessingVideo) _buildProcessingOverlay(state),
      ],
    );
  }

  Widget _buildInteractiveFeed({
    required CinemaCameraState state,
    required Size viewport,
    required bool haptics,
    required bool isLandscape,
    required bool hasLiveMetal,
  }) {
    // NativeCinemaCameraEngine reports portrait dimensions (e.g. 1080×1920).
    final previewSize = state.previewSize;
    final feedWidth = isLandscape ? previewSize.height : previewSize.width;
    final feedHeight = isLandscape ? previewSize.width : previewSize.height;

    final textureFeed = SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: feedWidth,
          height: feedHeight,
          child: Texture(textureId: state.liveMetalTextureId!),
        ),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) =>
          _handleFocusTap(details.localPosition, viewport, haptics),
      onScaleStart: (_) => _scaleStartZoom = state.zoomLevel,
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
          if (hasLiveMetal)
            textureFeed
          else
            ColorFiltered(
              colorFilter: ColorFilter.matrix(state.activeColorMatrix),
              child: textureFeed,
            ),
          if (!hasLiveMetal && !state.filmLook.isNeutral)
            IgnorePointer(
              child: _FilmPreviewOverlay(look: state.filmLook),
            ),
        ],
      ),
    );
  }

  Widget _buildActiveBadges(CinemaCameraState state, bool hasLiveMetal) {
    final chips = <String>[
      if (hasLiveMetal) 'METAL',
      if (state.hasHardwareDepth && state.captureMode.isBokehMode) 'LiDAR',
      if (state.captureMode.isBokehMode)
        'f/${state.apertureFStop.toStringAsFixed(1)}',
      if (state.hiRes48MP && state.captureMode.isPhoto) '48MP',
      if (state.processZeroEnabled && state.captureMode.isPhoto)
        state.saveDngRaw ? 'RAW+DNG' : 'RAW',
      if (state.processZeroEnabled &&
          state.nightStack &&
          state.captureMode.isPhoto)
        'STACK',
      if (state.heif10Bit && state.captureMode.isPhoto) '10B',
      if (state.proResEnabled &&
          state.captureMode == CinemaCaptureMode.video24fps)
        'PRORES',
      if (state.captureMode == CinemaCaptureMode.cinematicVideo) '10B·P3',
      if (state.appleLogEnabled) 'LOG',
      if (state.focusPeakingEnabled) 'PEAK',
      if (state.zebraEnabled) 'ZEBRA',
      if (state.falseColorEnabled) 'IRE',
      if (state.manualFocusEnabled) 'MF',
    ];
    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: chips
          .map(
            (label) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.56),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: AppTheme.cinemaAmber.withValues(alpha: 0.55),
                  width: 0.7,
                ),
              ),
              child: Text(
                label,
                style: AppTheme.monoStyle(
                  color: AppTheme.cinemaAmber,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildViewfinderBottomRow(CinemaCameraState state, bool haptics) {
    final isBack = state.lensDirection == CameraLensDirection.back;
    final showLenses = isBack && state.backLenses.length > 1;

    return Row(
      children: [
        // Left: Grid toggle + Flash icon
        _GlassMiniButton(
          icon: Icons.grid_3x3_rounded,
          active: state.showGrid,
          onTap: () {
            if (haptics) HapticFeedback.selectionClick();
            _notifier.toggleGrid();
          },
        ),
        const SizedBox(width: 6),
        _GlassMiniButton(
          icon: _flashIcon(state.flashMode),
          active: state.flashMode != FlashMode.off,
          onTap: () {
            if (haptics) HapticFeedback.selectionClick();
            _notifier.cycleFlashMode();
          },
        ),
        const SizedBox(width: 6),
        _GlassTextChip(
          label: state.timerSeconds == 0 ? '⏱' : '${state.timerSeconds}s',
          active: state.timerSeconds > 0,
          onTap: () {
            if (haptics) HapticFeedback.selectionClick();
            _notifier.cycleTimerSeconds();
          },
        ),
        const Spacer(),
        // Center: Optical Multi-Lens switcher (0.5× · 1× · TEL)
        if (showLenses)
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.56),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white12, width: 0.8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < state.backLenses.length; i++)
                  GestureDetector(
                    onTap: state.isRecordingVideo
                        ? null
                        : () {
                            if (haptics) HapticFeedback.selectionClick();
                            _notifier.switchBackLens(i);
                          },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: state.activeBackLensIndex == i
                            ? AppTheme.cinemaAmber
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        state.backLenses[i].label,
                        style: AppTheme.monoStyle(
                          color: state.activeBackLensIndex == i
                              ? Colors.black
                              : Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const Spacer(),
        // Right: HL Metering & 180° quick toggles
        _GlassTextChip(
          label: 'HL',
          active: state.highlightMeteringEnabled,
          onTap: () {
            if (haptics) HapticFeedback.selectionClick();
            _notifier
                .setHighlightMeteringEnabled(!state.highlightMeteringEnabled);
          },
        ),
        if (state.proCapabilities.available) ...[
          const SizedBox(width: 6),
          _GlassTextChip(
            label: '180°',
            active: state.is180ShutterLocked,
            onTap: () {
              if (haptics) HapticFeedback.selectionClick();
              _notifier.toggle180DegreeShutter();
            },
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------- bottom deck

  Widget _buildBottomDeck(
    CinemaCameraState state,
    CameraOptionsState options, {
    required bool isLandscape,
  }) {
    final s = AppStrings.of(context);
    final haptics = options.hapticFeedback;
    final showTray = !isLandscape || _trayVisible;

    return Container(
      decoration: BoxDecoration(
        color: isLandscape
            ? Colors.black.withValues(alpha: 0.78)
            : AppTheme.backgroundBlack,
        border: const Border(
          top: BorderSide(color: AppTheme.hairline, width: 0.7),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            0,
            isLandscape ? 6 : 10,
            0,
            isLandscape ? 6 : 10,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showTray) ...[
                ToneSelectorStrip(
                  tones: state.tones,
                  selectedTone: state.selectedTone,
                  onToneSelected: _notifier.selectTone,
                  onOpenCustomCreator: _openCustomToneEditor,
                  onDeleteCustomTone: _confirmDeleteTone,
                  compact: isLandscape,
                ),
                const SizedBox(height: 6),
                _buildMixSlider(state, s),
              ],
              const SizedBox(height: 4),
              _buildModeSelector(state, s, haptics),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: _buildShutterRow(state, haptics, isLandscape),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMixSlider(CinemaCameraState state, AppStrings s) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          Text(
            s.mix,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 1.8,
                  activeTrackColor: AppTheme.cinemaAmber,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: AppTheme.cinemaAmber,
                  overlayColor: AppTheme.cinemaAmber.withValues(alpha: 0.16),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 11),
                ),
                child: Slider(
                  value: state.intensity.clamp(0.0, 1.0),
                  onChanged: _notifier.setIntensity,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${(state.intensity * 100).round()}%',
              textAlign: TextAlign.right,
              style: AppTheme.monoStyle(
                color: AppTheme.textSecondary,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildApertureBar(CinemaCameraState state, bool haptics) {
    final s = AppStrings.of(context);
    const stops = <double>[1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_apertureSliderExpanded)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppTheme.cinemaAmber.withValues(alpha: 0.45),
                width: 0.8,
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final f in stops)
                    GestureDetector(
                      onTap: () {
                        if (haptics) HapticFeedback.selectionClick();
                        _notifier.setApertureFStop(f);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: (state.apertureFStop - f).abs() < 0.25
                              ? AppTheme.cinemaAmber
                              : Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'f/${f == f.roundToDouble() ? f.toInt() : f.toStringAsFixed(1)}',
                          style: AppTheme.monoStyle(
                            color: (state.apertureFStop - f).abs() < 0.25
                                ? Colors.black
                                : Colors.white70,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () {
                if (haptics) HapticFeedback.selectionClick();
                setState(
                    () => _apertureSliderExpanded = !_apertureSliderExpanded);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: _apertureSliderExpanded
                      ? AppTheme.cinemaAmber
                      : Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.cinemaAmber.withValues(alpha: 0.7),
                    width: 0.9,
                  ),
                ),
                child: Text(
                  '${s.aperture}  f/${state.apertureFStop.toStringAsFixed(1)}',
                  style: AppTheme.monoStyle(
                    color: _apertureSliderExpanded
                        ? Colors.black
                        : AppTheme.cinemaAmber,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            if (state.captureMode == CinemaCaptureMode.cinematicVideo) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  if (haptics) HapticFeedback.selectionClick();
                  _notifier.toggleCinematicRackFocus();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: state.cinematicRackedToBg
                        ? AppTheme.cinemaAmber.withValues(alpha: 0.22)
                        : Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: state.cinematicRackedToBg
                          ? AppTheme.cinemaAmber
                          : Colors.white24,
                      width: 0.9,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        state.cinematicRackedToBg
                            ? Icons.landscape_rounded
                            : Icons.person_outline_rounded,
                        color: state.cinematicRackedToBg
                            ? AppTheme.cinemaAmber
                            : Colors.white,
                        size: 12,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        state.cinematicRackedToBg
                            ? s.rackBackground
                            : s.rackSubject,
                        style: AppTheme.monoStyle(
                          color: state.cinematicRackedToBg
                              ? AppTheme.cinemaAmber
                              : Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildModeSelector(
    CinemaCameraState state,
    AppStrings s,
    bool haptics,
  ) {
    Widget modeItem(String label, CinemaCaptureMode mode) {
      final active = state.captureMode == mode;
      final accentColor =
          mode.isVideo ? AppTheme.cinemaRed : AppTheme.cinemaAmber;

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: state.isRecordingVideo || active
            ? null
            : () {
                if (haptics) HapticFeedback.selectionClick();
                if (!mode.isBokehMode && _apertureSliderExpanded) {
                  setState(() => _apertureSliderExpanded = false);
                }
                _applyProfile(
                  () => _notifier.setCaptureMode(mode),
                  label,
                );
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: active ? accentColor : AppTheme.textSecondary,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: active ? 4 : 0,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          modeItem(s.portrait, CinemaCaptureMode.portrait),
          modeItem(s.photo, CinemaCaptureMode.photo),
          modeItem(s.video, CinemaCaptureMode.video24fps),
          modeItem(s.cinematic, CinemaCaptureMode.cinematicVideo),
        ],
      ),
    );
  }

  Widget _buildShutterRow(
    CinemaCameraState state,
    bool haptics,
    bool isLandscape,
  ) {
    final thumbPath = state.latestGalleryThumbPath;
    final hasThumb =
        thumbPath != null && thumbPath.isNotEmpty && File(thumbPath).existsSync();

    return Row(
      children: [
        // Left: Gallery Thumbnail button
        SizedBox(
          width: 96,
          child: Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: state.isRecordingVideo
                  ? null
                  : () async {
                      if (haptics) HapticFeedback.selectionClick();
                      await context.push('/gallery');
                      if (mounted) {
                        _notifier.resumeCameraSession();
                        unawaited(_notifier.refreshLatestThumb());
                      }
                    },
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.22),
                    width: 1.0,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: hasThumb
                    ? Image.file(
                        File(thumbPath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.photo_library_outlined,
                          color: Colors.white70,
                          size: 20,
                        ),
                      )
                    : const Icon(
                        Icons.photo_library_outlined,
                        color: Colors.white70,
                        size: 20,
                      ),
              ),
            ),
          ),
        ),

        const Spacer(),

        // Center: Leica Matte Tactile Shutter Ring
        _buildShutterButton(state, haptics),

        const Spacer(),

        // Right: Pro Control Drawer ("M") + Flip Camera
        SizedBox(
          width: 96,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (isLandscape) ...[
                _CircleControl(
                  icon: _trayVisible
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.tune_rounded,
                  active: _trayVisible,
                  onTap: () => setState(() => _trayVisible = !_trayVisible),
                ),
                const SizedBox(width: 8),
              ] else ...[
                GestureDetector(
                  onTap: () => _openDrawer(0, haptics),
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: state.isManualCaptureActive
                          ? AppTheme.cinemaAmber.withValues(alpha: 0.16)
                          : AppTheme.cardDark,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: state.isManualCaptureActive
                            ? AppTheme.cinemaAmber
                            : Colors.white24,
                        width: 1.0,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'M',
                        style: TextStyle(
                          color: state.isManualCaptureActive
                              ? AppTheme.cinemaAmber
                              : Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              _CircleControl(
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

  Widget _buildShutterButton(CinemaCameraState state, bool haptics) {
    final isVideo = state.captureMode.isVideo;
    final isBusy = state.isCapturing ||
        _isCapturingPhoto ||
        _isTogglingVideo ||
        state.isProcessingVideo;

    return GestureDetector(
      onTap: isBusy
          ? null
          : () => isVideo
              ? _handleVideoToggle(haptics)
              : _triggerPhotoWithTimer(haptics),
      child: Container(
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: isVideo ? AppTheme.cinemaRed : Colors.white,
            width: 3.2,
          ),
        ),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: state.isRecordingVideo ? 26 : 58,
            height: state.isRecordingVideo ? 26 : 58,
            decoration: BoxDecoration(
              color: isVideo ? AppTheme.cinemaRed : Colors.white,
              borderRadius:
                  BorderRadius.circular(state.isRecordingVideo ? 6 : 29),
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- badges

  Widget _buildZoomIndicator(CinemaCameraState state) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        _notifier.resetZoom();
        _flashZoomIndicator();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppTheme.cinemaAmber.withValues(alpha: 0.6),
          ),
        ),
        child: Text(
          '${state.zoomLevel.toStringAsFixed(1)}×',
          style: AppTheme.monoStyle(
            color: AppTheme.cinemaAmber,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingBadge(CinemaCameraState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.cinemaRed.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.white, size: 10),
          const SizedBox(width: 6),
          Text(
            _formatDuration(state.recordingDuration),
            style: AppTheme.monoStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProcessingOverlay(CinemaCameraState state) {
    final progress = state.videoProcessingProgress;
    final label = state.videoProcessingLabel ?? 'Processing...';

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.65),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  color: AppTheme.cinemaAmber,
                  value: progress,
                  strokeWidth: 2.8,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                progress == null
                    ? label
                    : '$label ${(progress * 100).round()}%',
                style: AppTheme.monoStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- actions

  void _openDrawer(int tab, bool haptics) {
    if (haptics) HapticFeedback.selectionClick();
    showCinemaControlDrawer(context, initialTab: tab);
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

  Future<void> _applyProfile(
    Future<void> Function() action,
    String label,
  ) async {
    if (_isSwitchingQuality) return;
    setState(() => _isSwitchingQuality = true);
    try {
      await action();
    } catch (error) {
      _toast('$label: ${_describe(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _isSwitchingQuality = false);
    }
  }

  void _triggerPhotoWithTimer(bool haptics) {
    if (_countdownRemaining > 0) {
      _countdownTimer?.cancel();
      setState(() => _countdownRemaining = 0);
      return;
    }
    final timerSeconds =
        ref.read(cinemaCameraProvider).valueOrNull?.timerSeconds ?? 0;
    if (timerSeconds <= 0) {
      unawaited(_handlePhotoCapture(haptics));
      return;
    }
    if (haptics) HapticFeedback.selectionClick();
    setState(() => _countdownRemaining = timerSeconds);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdownRemaining <= 1) {
        timer.cancel();
        setState(() => _countdownRemaining = 0);
        unawaited(_handlePhotoCapture(haptics));
      } else {
        if (haptics) HapticFeedback.selectionClick();
        setState(() => _countdownRemaining -= 1);
      }
    });
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

      await context.push(
        '/preview',
        extra: CapturedPreviewArgs.photo(
          imageBytes: result.bytes,
          tone: state.selectedTone,
          intensity: state.intensity,
          isAnamorphic: state.isAnamorphicRatio,
        ),
      );
      if (mounted) _notifier.resumeCameraSession();
    } catch (error) {
      _toast(_describe(error), isError: true);
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
          _toast('Recording not saved.', isError: true);
          return;
        }
        if (result.warning != null) _toast(result.warning!);
        await context.push(
          '/preview',
          extra: CapturedPreviewArgs.video(
            videoFilePath: result.path,
            tone: state.selectedTone,
            intensity: state.intensity,
            isAnamorphic: state.isAnamorphicRatio,
          ),
        );
        if (mounted) _notifier.resumeCameraSession();
      } else {
        await _lockOrientationForRecording();
        if (!mounted) return;
        await _notifier.startVideo24fpsRecording();
      }
    } catch (error) {
      await _unlockOrientation();
      _toast(_describe(error), isError: true);
    } finally {
      if (mounted) setState(() => _isTogglingVideo = false);
    }
  }

  Future<void> _lockOrientationForRecording() async {
    final lockLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
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
      _toast(_describe(error), isError: true);
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

  Future<void> _confirmDeleteTone(CinemaTone tone) async {
    final s = AppStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(
          '${s.delete} "${tone.name}"?',
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              s.delete,
              style: const TextStyle(color: AppTheme.cinemaRed),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _notifier.deleteCustomTone(tone.id);
    } catch (error) {
      _toast(_describe(error), isError: true);
    }
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 12.5)),
        backgroundColor:
            isError ? const Color(0xFFB3261E) : AppTheme.cardDark,
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
    final m = duration.inMinutes.toString().padLeft(2, '0');
    final sec = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  IconData _flashIcon(FlashMode mode) => switch (mode) {
        FlashMode.off => Icons.flash_off_rounded,
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.always => Icons.flash_on_rounded,
        FlashMode.torch => Icons.highlight_rounded,
      };
}

// ----------------------------------------------------------------- subwidgets

class _TelemetryCell extends StatelessWidget {
  final String label;
  final String value;
  final bool accent;
  final VoidCallback onTap;

  const _TelemetryCell({
    required this.label,
    required this.value,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.monoStyle(
                color: accent ? AppTheme.cinemaAmber : AppTheme.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TelemetryDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(width: 0.7, height: 22, color: AppTheme.hairline);
  }
}

class _GlassMiniButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _GlassMiniButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.56),
          shape: BoxShape.circle,
          border: Border.all(
            color: active ? AppTheme.cinemaAmber : Colors.white12,
            width: 0.9,
          ),
        ),
        child: Icon(
          icon,
          size: 16,
          color: active ? AppTheme.cinemaAmber : Colors.white70,
        ),
      ),
    );
  }
}

class _GlassTextChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _GlassTextChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.cinemaAmber
              : Colors.black.withValues(alpha: 0.56),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? AppTheme.cinemaAmber : Colors.white12,
            width: 0.9,
          ),
        ),
        child: Text(
          label,
          style: AppTheme.monoStyle(
            color: active ? Colors.black : Colors.white70,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _CircleControl extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;

  const _CircleControl({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap!();
            },
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          shape: BoxShape.circle,
          border: Border.all(
            color: active ? AppTheme.cinemaAmber : Colors.white24,
            width: 1.0,
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
}

/// Draws the matte viewfinder crop mask for vintage & cinema aspect ratios
/// (`1:1`, `4:5`, `6:7`, `3:2`, `16:9`, `2.39:1`, `65:24` XPan) with delicate
/// Leica corner ticks.
class _FrameAspectMask extends StatelessWidget {
  final double aspectRatio;
  final bool isLandscape;

  const _FrameAspectMask({
    required this.aspectRatio,
    required this.isLandscape,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        if (w <= 0 || h <= 0) return const SizedBox.shrink();

        // In portrait, aspect ratios > 1.8 (like 2.39:1 or 65:24 XPan) remain
        // horizontal panoramic frames; classic photography ratios (3:2, 16:9)
        // orient naturally with the device unless already portrait (4:5, 6:7).
        final double effectiveRatio;
        if (isLandscape) {
          effectiveRatio = aspectRatio < 1.0 ? 1.0 / aspectRatio : aspectRatio;
        } else {
          effectiveRatio = aspectRatio;
        }

        double frameW = w;
        double frameH = w / effectiveRatio;
        if (frameH > h) {
          frameH = h;
          frameW = h * effectiveRatio;
        }

        final barH = ((h - frameH) / 2).clamp(0.0, h);
        final barW = ((w - frameW) / 2).clamp(0.0, w);
        final maskColor = Colors.black.withValues(alpha: 0.72);

        return Stack(
          children: [
            if (barH > 0.5) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: barH,
                child: ColoredBox(color: maskColor),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: barH,
                child: ColoredBox(color: maskColor),
              ),
            ],
            if (barW > 0.5) ...[
              Positioned(
                top: barH,
                bottom: barH,
                left: 0,
                width: barW,
                child: ColoredBox(color: maskColor),
              ),
              Positioned(
                top: barH,
                bottom: barH,
                right: 0,
                width: barW,
                child: ColoredBox(color: maskColor),
              ),
            ],
            Center(
              child: Container(
                width: frameW,
                height: frameH,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppTheme.cinemaAmber.withValues(alpha: 0.45),
                    width: 0.9,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CinemaLoadingView extends StatelessWidget {
  const _CinemaLoadingView();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppTheme.backgroundBlack,
      child: Center(
        child: CircularProgressIndicator(
          color: AppTheme.cinemaAmber,
          strokeWidth: 2.5,
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
    final s = AppStrings.of(context);
    return ColoredBox(
      color: AppTheme.backgroundBlack,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off_rounded,
                color: Colors.white54,
                size: 42,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.cinemaAmber,
                  foregroundColor: Colors.black,
                ),
                onPressed: onRetry,
                child: Text(s.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
              painter: _GrainPainter(strength: grain, size: look.grainSize),
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

class _GrainPainter extends CustomPainter {
  final double strength;
  final double size;

  const _GrainPainter({required this.strength, required this.size});

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (canvasSize.isEmpty) return;
    final dot = 1.0 + size.clamp(0.0, 1.0) * 1.2;
    final count = ((canvasSize.width * canvasSize.height) / 260)
        .clamp(400.0, 2600.0)
        .round();
    final random = math.Random(20240517);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < count; i++) {
      final x = random.nextDouble() * canvasSize.width;
      final y = random.nextDouble() * canvasSize.height;
      final light = random.nextBool();
      final alpha = light ? 0.02 + strength * 0.09 : 0.02 + strength * 0.06;
      paint.color = (light ? Colors.white : Colors.black)
          .withValues(alpha: alpha.clamp(0.0, 0.3));
      canvas.drawRect(Rect.fromLTWH(x, y, dot, dot), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GrainPainter oldDelegate) =>
      oldDelegate.strength != strength || oldDelegate.size != size;
}

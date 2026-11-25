// lib/features/options/presentation/widgets/camera_options_sheet.dart

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../about/presentation/screens/about_screen.dart';
import '../../../cinema_camera/domain/entities/film_look.dart';
import '../../../cinema_camera/domain/entities/frame_format.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_provider.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_state.dart';
import '../../../cinema_camera/presentation/widgets/dop_overlays.dart';
import '../../../cinema_camera/presentation/widgets/preset_library_io_sheet.dart';
import '../../domain/entities/camera_options_state.dart';
import '../providers/camera_options_provider.dart';

/// Opens the 4-Tab Tactile Control Drawer directly to a specific tab:
/// `0 = EXPOSURE`, `1 = LOOK`, `2 = OPTICS`, `3 = CAMERA`.
Future<void> showCinemaControlDrawer(
  BuildContext context, {
  int initialTab = 0,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surfaceDark,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => CameraOptionsSheet(initialTab: initialTab),
  );
}

class CameraOptionsButton extends ConsumerWidget {
  const CameraOptionsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hapticEnabled = ref.watch(
      cameraOptionsProvider.select((s) => s.hapticFeedback),
    );

    return GestureDetector(
      onTap: () {
        if (hapticEnabled) HapticFeedback.lightImpact();
        showCinemaControlDrawer(context);
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppTheme.cardDark.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          border: Border.all(
            color: AppTheme.cinemaAmber.withValues(alpha: 0.6),
            width: 1.1,
          ),
        ),
        child: const Center(
          child: Text(
            'M',
            style: TextStyle(
              color: AppTheme.cinemaAmber,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ),
    );
  }
}

/// Modular 4-Tab Pro Control Drawer (`EXPOSURE | LOOK | OPTICS | CAMERA`).
/// Zero verbose paragraphs; tactile rulers + 2×2 switch cards + vintage frame grid.
class CameraOptionsSheet extends ConsumerStatefulWidget {
  final int initialTab;

  const CameraOptionsSheet({super.key, this.initialTab = 0});

  @override
  ConsumerState<CameraOptionsSheet> createState() => _CameraOptionsSheetState();
}

class _CameraOptionsSheetState extends ConsumerState<CameraOptionsSheet> {
  late int _activeTab = widget.initialTab.clamp(0, 3);
  List<Map<String, dynamic>> _audioInputs = const [];

  @override
  void initState() {
    super.initState();
    _loadAudioInputs();
  }

  Future<void> _loadAudioInputs() async {
    final inputs =
        await ref.read(cinemaCameraRepositoryProvider).listAudioInputs();
    if (mounted) {
      setState(() => _audioInputs = inputs);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final options = ref.watch(cameraOptionsProvider);
    final optionsNotifier = ref.read(cameraOptionsProvider.notifier);
    final cameraState = ref.watch(cinemaCameraProvider).valueOrNull;
    final cameraNotifier = ref.read(cinemaCameraProvider.notifier);
    final haptics = options.hapticFeedback;

    final tabs = [s.tabExposure, s.tabLook, s.tabOptics, s.tabCamera];

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            // 4-Tab Segmented Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundBlack,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.hairline),
                ),
                child: Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            if (haptics) HapticFeedback.selectionClick();
                            setState(() => _activeTab = i);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: _activeTab == i
                                  ? AppTheme.cinemaAmber
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              tabs[i],
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _activeTab == i
                                    ? Colors.black
                                    : AppTheme.textSecondary,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: cameraState == null
                    ? const SizedBox(height: 120)
                    : switch (_activeTab) {
                        0 => _buildExposureTab(
                            context, s, cameraState, cameraNotifier, haptics),
                        1 => _buildLookTab(
                            context, s, cameraState, cameraNotifier, haptics),
                        2 => _buildOpticsTab(context, s, cameraState,
                            cameraNotifier, options, optionsNotifier, haptics),
                        _ => _buildCameraTab(context, s, cameraState,
                            cameraNotifier, options, optionsNotifier, haptics),
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------- TAB 0: EXPOSURE

  Widget _buildExposureTab(
    BuildContext context,
    AppStrings s,
    CinemaCameraState state,
    CinemaCameraNotifier notifier,
    bool haptics,
  ) {
    final caps = state.proCapabilities;
    final available = caps.available;
    final minLogShutter =
        math.log(caps.minShutterSeconds.clamp(1 / 16000, 1.0));
    final maxLogShutter = math.log(caps.maxShutterSeconds.clamp(1 / 1000, 1.0));
    final curLogShutter = math.log(
      state.shutterSeconds
          .clamp(caps.minShutterSeconds, caps.maxShutterSeconds),
    );
    final minLogIso = math.log(caps.minIso.clamp(16.0, 100000.0));
    final maxLogIso = math.log(caps.maxIso.clamp(100.0, 100000.0));
    final curLogIso = math.log(state.iso.clamp(caps.minIso, caps.maxIso));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.proControlError != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: AppTheme.cinemaRed.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppTheme.cinemaRed.withValues(alpha: 0.5),
              ),
            ),
            child: Text(
              state.proControlError!,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
        TactileRulerSlider(
          label: s.shutterSpeed,
          valueText: state.manualExposureEnabled ? state.shutterLabel : 'AUTO',
          value: curLogShutter,
          min: minLogShutter,
          max: maxLogShutter,
          enabled: available,
          autoActive: !state.manualExposureEnabled,
          haptics: haptics,
          onToggleAuto: () =>
              notifier.setManualExposureEnabled(!state.manualExposureEnabled),
          onChanged: (v) =>
              notifier.previewManualExposure(shutterSeconds: math.exp(v)),
          onChangeEnd: notifier.commitManualExposure,
        ),
        const SizedBox(height: 8),
        TactileRulerSlider(
          label: s.isoSensitivity,
          valueText:
              state.manualExposureEnabled ? '${state.iso.round()}' : 'AUTO',
          value: curLogIso,
          min: minLogIso,
          max: maxLogIso,
          enabled: available,
          autoActive: !state.manualExposureEnabled,
          haptics: haptics,
          onToggleAuto: () =>
              notifier.setManualExposureEnabled(!state.manualExposureEnabled),
          onChanged: (v) => notifier.previewManualExposure(iso: math.exp(v)),
          onChangeEnd: notifier.commitManualExposure,
        ),
        const SizedBox(height: 8),
        TactileRulerSlider(
          label: s.whiteBalance,
          valueText: state.manualWhiteBalanceEnabled
              ? '${state.whiteBalanceKelvin}K'
              : 'AUTO',
          value: state.whiteBalanceKelvin.toDouble(),
          min: 2200,
          max: 9500,
          enabled: available,
          autoActive: !state.manualWhiteBalanceEnabled,
          haptics: haptics,
          onToggleAuto: () => notifier
              .setManualWhiteBalanceEnabled(!state.manualWhiteBalanceEnabled),
          onChanged: (v) =>
              notifier.previewManualWhiteBalance(kelvin: (v / 50).round() * 50),
          onChangeEnd: notifier.commitManualWhiteBalance,
        ),
        const SizedBox(height: 8),
        TactileRulerSlider(
          label: s.manualFocus,
          valueText: state.manualFocusEnabled
              ? '${(state.focusPosition * 100).round()}%'
              : 'AF',
          value: state.focusPosition,
          min: 0.0,
          max: 1.0,
          enabled: available,
          autoActive: !state.manualFocusEnabled,
          haptics: haptics,
          onToggleAuto: () =>
              notifier.setManualFocusEnabled(!state.manualFocusEnabled),
          onChanged: notifier.previewManualFocus,
        ),
        const SizedBox(height: 12),
        _ToggleGrid(
          cards: [
            _SwitchCardData(
              title: s.processZero,
              subtitle: s.processZeroSub,
              active: state.processZeroEnabled,
              onTap: () =>
                  notifier.setProcessZeroEnabled(!state.processZeroEnabled),
            ),
            _SwitchCardData(
              title: s.saveDngRaw,
              subtitle: s.saveDngRawSub,
              active: state.saveDngRaw,
              enabled: state.processZeroEnabled,
              onTap: () => notifier.setSaveDngRaw(!state.saveDngRaw),
            ),
            _SwitchCardData(
              title: s.nightStack,
              subtitle: s.nightStackSub,
              active: state.nightStack,
              enabled: state.processZeroEnabled,
              onTap: () => notifier.setNightStack(!state.nightStack),
            ),
            _SwitchCardData(
              title: s.heif10Bit,
              subtitle: s.heif10BitSub,
              active: state.heif10Bit,
              onTap: () => notifier.setHeif10Bit(!state.heif10Bit),
            ),
            if (caps.supports48MP || state.hiRes48MP)
              _SwitchCardData(
                title: s.hiRes48MP,
                subtitle: s.hiRes48MPSub,
                active: state.hiRes48MP,
                enabled: !state.isRecordingVideo,
                onTap: () => notifier.setHiRes48MP(!state.hiRes48MP),
              ),
            _SwitchCardData(
              title: s.hlMetering,
              subtitle: s.hlMeteringSub,
              active: state.highlightMeteringEnabled,
              onTap: () => notifier
                  .setHighlightMeteringEnabled(!state.highlightMeteringEnabled),
            ),
            _SwitchCardData(
              title: s.rule180,
              subtitle: '1/${state.frameRate.value * 2}s',
              active: state.is180ShutterLocked,
              enabled: available,
              onTap: notifier.toggle180DegreeShutter,
            ),
            if (caps.supportsAppleLog)
              _SwitchCardData(
                title: s.appleLog,
                subtitle: s.appleLogSub,
                active: state.appleLogEnabled,
                onTap: () => notifier.setAppleLog(!state.appleLogEnabled),
              ),
            if (caps.supportsProRes)
              _SwitchCardData(
                title: s.proRes422,
                subtitle: s.proRes422Sub,
                active: state.proResEnabled,
                enabled: !state.isRecordingVideo,
                onTap: () => notifier.setProResEnabled(!state.proResEnabled),
              ),
          ],
          haptics: haptics,
        ),
      ],
    );
  }

  // --------------------------------------------------------------- TAB 1: LOOK

  Widget _buildLookTab(
    BuildContext context,
    AppStrings s,
    CinemaCameraState state,
    CinemaCameraNotifier notifier,
    bool haptics,
  ) {
    final look = state.filmLook;
    void update(FilmLook next) => notifier.setFilmLook(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Import .cube action
        GestureDetector(
          onTap: () async {
            if (haptics) HapticFeedback.selectionClick();
            final added = await notifier.importCubeLuts();
            if (!context.mounted || added == 0) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$added .cube LUT imported'),
                backgroundColor: AppTheme.cardDark,
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppTheme.cinemaAmber.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.cinemaAmber.withValues(alpha: 0.65),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.file_upload_outlined,
                  color: AppTheme.cinemaAmber,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  s.importCube,
                  style: const TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _ToggleGrid(
          haptics: haptics,
          cards: [
            _SwitchCardData(
              title: s.stockEffects,
              subtitle: s.stockEffectsSub,
              active: look.useStockEffects,
              onTap: () => update(
                look.copyWith(useStockEffects: !look.useStockEffects),
              ),
            ),
            if (state.proCapabilities.supportsProRes)
              _SwitchCardData(
                title: s.bakeProRes,
                subtitle: s.bakeProResSub,
                active: state.bakeLookIntoProRes,
                enabled: !state.isRecordingVideo,
                onTap: () =>
                    notifier.setBakeLookIntoProRes(!state.bakeLookIntoProRes),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _CompactSliderRow(
          label: s.deepShadow,
          value: look.shadowDepth,
          onChanged: (v) => update(look.copyWith(shadowDepth: v)),
        ),
        _CompactSliderRow(
          label: s.acutance,
          value: look.acutance,
          onChanged: (v) => update(look.copyWith(acutance: v)),
        ),
        _CompactSliderRow(
          label: s.filmicRollOff,
          value: look.filmicRollOff,
          onChanged: (v) => update(look.copyWith(filmicRollOff: v)),
        ),
        if (!look.useStockEffects) ...[
          const SizedBox(height: 4),
          _CompactSliderRow(
            label: s.grain,
            value: look.grain,
            onChanged: (v) => update(look.copyWith(grain: v)),
          ),
          _CompactSliderRow(
            label: s.grainSize,
            value: look.grainSize,
            onChanged: (v) => update(look.copyWith(grainSize: v)),
          ),
          _CompactSliderRow(
            label: s.halation,
            value: look.halation,
            onChanged: (v) => update(look.copyWith(halation: v)),
          ),
          _CompactSliderRow(
            label: s.bloom,
            value: look.bloom,
            onChanged: (v) => update(look.copyWith(bloom: v)),
          ),
          _CompactSliderRow(
            label: s.vignette,
            value: look.vignette,
            onChanged: (v) => update(look.copyWith(vignette: v)),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------- TAB 2: OPTICS

  Widget _buildOpticsTab(
    BuildContext context,
    AppStrings s,
    CinemaCameraState state,
    CinemaCameraNotifier notifier,
    CameraOptionsState options,
    CameraOptionsNotifier optionsNotifier,
    bool haptics,
  ) {
    final isBusy = state.isRecordingVideo;
    const desqueezeChoices = [1.0, 1.33, 1.55];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(s.frameFormat),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.28,
          children: CameraFrameFormat.values.map((fmt) {
            final selected = state.frameFormat == fmt;
            return GestureDetector(
              onTap: isBusy
                  ? null
                  : () {
                      if (haptics) HapticFeedback.selectionClick();
                      notifier.setFrameFormat(fmt);
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.cinemaAmber.withValues(alpha: 0.16)
                      : AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? AppTheme.cinemaAmber : AppTheme.hairline,
                    width: selected ? 1.3 : 0.9,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      fmt.label,
                      style: AppTheme.monoStyle(
                        color: selected
                            ? AppTheme.cinemaAmber
                            : AppTheme.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      fmt.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 8.5,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        _ToggleGrid(
          haptics: haptics,
          cards: [
            _SwitchCardData(
              title: s.trueCrop,
              subtitle: s.trueCropSub,
              active: state.anamorphicCrop,
              enabled: !isBusy && state.effectiveFrameAspectRatio > 0.1,
              onTap: () => notifier.setAnamorphicCrop(!state.anamorphicCrop),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _SectionLabel(s.desqueeze),
        const SizedBox(height: 8),
        Row(
          children: desqueezeChoices.map((factor) {
            final selected = (state.anamorphicDesqueeze - factor).abs() < 0.02;
            final label =
                factor == 1.0 ? s.off : '${factor.toStringAsFixed(2)}×';
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _PillChoice(
                  label: label,
                  selected: selected,
                  enabled: !isBusy,
                  onTap: () {
                    if (haptics) HapticFeedback.selectionClick();
                    notifier.setAnamorphicDesqueeze(factor);
                  },
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        _SectionLabel(s.grid),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: GridOverlayType.values.map((type) {
            final selected = options.gridType == type;
            return _PillChoice(
              label: type.label,
              selected: selected,
              onTap: () {
                if (haptics) HapticFeedback.selectionClick();
                optionsNotifier.setGridType(type);
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- TAB 3: CAMERA

  Widget _buildCameraTab(
    BuildContext context,
    AppStrings s,
    CinemaCameraState state,
    CinemaCameraNotifier notifier,
    CameraOptionsState options,
    CameraOptionsNotifier optionsNotifier,
    bool haptics,
  ) {
    final isBusy = state.isRecordingVideo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(s.resolution),
        const SizedBox(height: 8),
        Row(
          children: CaptureResolution.values.map((res) {
            final selected = state.resolution == res;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _PillChoice(
                  label: res.label,
                  selected: selected,
                  enabled: !isBusy,
                  onTap: () {
                    if (haptics) HapticFeedback.selectionClick();
                    notifier.setResolution(res);
                  },
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        _SectionLabel(s.frameRate),
        const SizedBox(height: 8),
        Row(
          children: CaptureFrameRate.values.map((fps) {
            final selected = state.frameRate == fps;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: _PillChoice(
                  label: '${fps.label} FPS',
                  selected: selected,
                  enabled: !isBusy,
                  onTap: () {
                    if (haptics) HapticFeedback.selectionClick();
                    notifier.setFrameRate(fps);
                  },
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        // Tahap 2 Metal Preview & Direct LUT Recording
        _ToggleGrid(
          haptics: haptics,
          cards: [
            _SwitchCardData(
              title: s.liveMetalLut,
              subtitle: s.liveMetalLutSub,
              active: state.liveMetalEnabled,
              enabled: !isBusy,
              onTap: () => notifier.setLiveMetalEnabled(!state.liveMetalEnabled),
            ),
            _SwitchCardData(
              title: s.directLutRec,
              subtitle: s.directLutRecSub,
              active: state.directLutRecordingEnabled,
              enabled: !isBusy,
              onTap: () => notifier
                  .setDirectLutRecordingEnabled(!state.directLutRecordingEnabled),
            ),
            _SwitchCardData(
              title: s.volumeShutter,
              subtitle: s.volumeShutterSub,
              active: state.volumeShutterEnabled,
              onTap: () =>
                  notifier.setVolumeShutterEnabled(!state.volumeShutterEnabled),
            ),
          ],
        ),
        if (_audioInputs.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionLabel(s.audioInput),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _audioInputs.map((input) {
              final uid = (input['uid'] ?? '').toString();
              final name = (input['name'] ?? 'Mic').toString();
              final selected = input['selected'] == true;
              return _PillChoice(
                label: name,
                selected: selected,
                enabled: !isBusy,
                onTap: () async {
                  if (haptics) HapticFeedback.selectionClick();
                  await ref
                      .read(cinemaCameraRepositoryProvider)
                      .selectAudioInput(uid);
                  await _loadAudioInputs();
                },
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 14),
        _SectionLabel(s.dopMonitors),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _PillChoice(
              label: s.focusPeaking,
              selected: state.focusPeakingEnabled,
              onTap: () =>
                  notifier.setDopOverlay(focusPeaking: !state.focusPeakingEnabled),
            ),
            _PillChoice(
              label: s.zebraStripes,
              selected: state.zebraEnabled,
              onTap: () => notifier.setDopOverlay(zebra: !state.zebraEnabled),
            ),
            _PillChoice(
              label: s.falseColor,
              selected: state.falseColorEnabled,
              onTap: () =>
                  notifier.setDopOverlay(falseColor: !state.falseColorEnabled),
            ),
            _PillChoice(
              label: s.horizonLevel,
              selected: state.horizonLevelEnabled,
              onTap: () =>
                  notifier.setDopOverlay(horizon: !state.horizonLevelEnabled),
            ),
            _PillChoice(
              label: s.audioMeter,
              selected: state.audioMeterEnabled,
              onTap: () =>
                  notifier.setDopOverlay(audioMeter: !state.audioMeterEnabled),
            ),
            _PillChoice(
              label: s.liveScope,
              selected: state.liveScopeEnabled,
              onTap: () =>
                  notifier.setDopOverlay(liveScope: !state.liveScopeEnabled),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _PillChoice(
                label: '${s.haptics}: ${options.hapticFeedback ? s.on : s.off}',
                selected: options.hapticFeedback,
                onTap: () =>
                    optionsNotifier.toggleHapticFeedback(!options.hapticFeedback),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PillChoice(
                label: s.presetLibrary,
                selected: false,
                onTap: () {
                  Navigator.pop(context);
                  showModalBottomSheet<void>(
                    context: context,
                    backgroundColor: Colors.transparent,
                    isScrollControlled: true,
                    builder: (_) => const PresetLibraryIoSheet(),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PillChoice(
                label: s.aboutApp,
                selected: false,
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
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
      ),
    );
  }
}

class _PillChoice extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _PillChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.cinemaAmber.withValues(alpha: 0.16)
              : AppTheme.cardDark,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppTheme.cinemaAmber : AppTheme.hairline,
            width: selected ? 1.2 : 0.9,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: !enabled
                ? Colors.white24
                : selected
                    ? AppTheme.cinemaAmber
                    : AppTheme.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _SwitchCardData {
  final String title;
  final String subtitle;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  const _SwitchCardData({
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
    this.enabled = true,
  });
}

class _ToggleGrid extends StatelessWidget {
  final List<_SwitchCardData> cards;
  final bool haptics;

  const _ToggleGrid({required this.cards, required this.haptics});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i += 2) {
      final left = cards[i];
      final right = i + 1 < cards.length ? cards[i + 1] : null;
      rows.add(
        Row(
          children: [
            Expanded(child: _buildCard(left)),
            const SizedBox(width: 8),
            Expanded(
              child: right != null ? _buildCard(right) : const SizedBox.shrink(),
            ),
          ],
        ),
      );
      if (i + 2 < cards.length) rows.add(const SizedBox(height: 8));
    }
    return Column(children: rows);
  }

  Widget _buildCard(_SwitchCardData card) {
    return GestureDetector(
      onTap: card.enabled
          ? () {
              if (haptics) HapticFeedback.selectionClick();
              card.onTap();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: card.active
              ? AppTheme.cinemaAmber.withValues(alpha: 0.14)
              : AppTheme.cardDark,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: card.active ? AppTheme.cinemaAmber : AppTheme.hairline,
            width: card.active ? 1.2 : 0.9,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: !card.enabled
                          ? Colors.white24
                          : card.active
                              ? AppTheme.cinemaAmber
                              : AppTheme.textPrimary,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    card.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 9.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: card.active
                    ? AppTheme.cinemaAmber
                    : Colors.white.withValues(alpha: 0.16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactSliderRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _CompactSliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: AppTheme.cinemaAmber,
                inactiveTrackColor: Colors.white12,
                thumbColor: AppTheme.cinemaAmber,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 13),
              ),
              child: Slider(
                value: value.clamp(0.0, 1.0),
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${(value * 100).round()}',
              textAlign: TextAlign.right,
              style: AppTheme.monoStyle(
                color: AppTheme.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// lib/features/photo_editor/presentation/screens/photo_editor_screen.dart

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../cinema_camera/domain/entities/cinema_tone.dart';
import '../../../cinema_camera/domain/entities/film_look.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_provider.dart';
import '../../../cinema_camera/presentation/widgets/tone_selector_strip.dart';
import '../../data/photo_editor_repository.dart';
import '../../domain/entities/photo_edit.dart';
import '../widgets/edit_slider.dart';
import '../widgets/tone_curve_editor.dart';

/// Full editor for photos and clips opened from the CineLens gallery.
///
/// Every slider maps to the native Core Image pipeline, so the preview here is
/// the same render the export produces: real tone curves, eight-band HSL and
/// the exact film-emulation cubes the camera uses.
class PhotoEditorScreen extends ConsumerStatefulWidget {
  final PhotoEditorArgs args;

  const PhotoEditorScreen({super.key, required this.args});

  @override
  ConsumerState<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends ConsumerState<PhotoEditorScreen> {
  static const CinemaTone _standardTone = CinemaTone(
    id: 'standard',
    name: 'Standard',
    filmReference: 'Netral',
    description: 'Tanpa tone film',
    accentColorHex: 0xFFE5A93B,
    matrix: CinemaTone.identityMatrix,
  );

  static const List<String> _tabLabels = <String>[
    'Cahaya',
    'Warna',
    'Kurva',
    'Campur',
    'Film',
    'Efek',
    'Detail',
  ];

  static const List<IconData> _tabIcons = <IconData>[
    Icons.wb_sunny_outlined,
    Icons.palette_outlined,
    Icons.show_chart_rounded,
    Icons.grain_rounded,
    Icons.movie_filter_outlined,
    Icons.auto_fix_high_outlined,
    Icons.blur_on_rounded,
  ];

  static const List<Color> _bandColors = <Color>[
    Color(0xFFFF5A5A),
    Color(0xFFFF9F43),
    Color(0xFFF5D547),
    Color(0xFF5AD27C),
    Color(0xFF3DD9C4),
    Color(0xFF4A8DFF),
    Color(0xFF9B6BFF),
    Color(0xFFE05AC8),
  ];

  Uint8List? _original;
  Uint8List? _preview;
  bool _loading = true;
  bool _rendering = false;
  bool _exporting = false;
  bool _showOriginal = false;
  String? _error;
  String? _renderError;

  /// Film effects sliders start neutral: the stock's own grain/halation apply
  /// by default, and these values only matter once the user switches them on.
  static const FilmLook _neutralFilm = FilmLook(
    grain: 0,
    grainSize: 0,
    halation: 0,
    bloom: 0,
    vignette: 0,
  );

  PhotoEdit _edit = PhotoEdit.neutral;
  FilmLook _film = _neutralFilm;
  String _toneId = 'standard';
  double _toneIntensity = 1.0;
  bool _stockEffects = true;

  int _tab = 0;
  EditCurveChannel _curveChannel = EditCurveChannel.rgb;
  int _hslBand = 0;

  Timer? _debounce;
  int _renderToken = 0;

  bool get _isVideo => widget.args.isVideo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  CinemaTone _resolveTone() {
    final tones = ref.read(cinemaCameraProvider).valueOrNull?.tones ??
        const <CinemaTone>[];
    for (final tone in tones) {
      if (tone.id == _toneId) return tone;
    }
    return _standardTone;
  }

  List<CinemaTone> _tones() {
    final tones = ref.watch(cinemaCameraProvider).valueOrNull?.tones ??
        const <CinemaTone>[];
    if (tones.isEmpty) return const <CinemaTone>[_standardTone];
    return tones;
  }

  Future<void> _load() async {
    try {
      final repository = ref.read(photoEditorRepositoryProvider);
      final original = await repository.loadPreview(
        path: widget.args.path,
        isVideo: _isVideo,
        maxDimension: 1400,
      );
      if (!mounted) return;
      setState(() {
        _original = original;
        _preview = original;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(error);
      });
    }
  }

  Map<String, dynamic> _payload() {
    final tone = _resolveTone();
    final payload = <String, dynamic>{
      'edit': _edit.toParameters(),
      'toneId': (tone.isLutTone || tone.isCustom) ? null : tone.id,
      'intensity': _toneIntensity,
      if (!tone.isLutTone && tone.isCustom)
        'matrix': tone.blendedMatrix(_toneIntensity),
    };

    if (tone.isLutTone) {
      payload['look'] = _film.copyWith(useStockEffects: false).toNative(
            lutPath: tone.lutPath,
            lutSize: tone.lutSize,
            mix: _toneIntensity,
          );
    } else if (!_stockEffects) {
      payload['look'] = _film.copyWith(useStockEffects: false).toNative();
    }
    return payload;
  }

  bool get _previewIsNeutral {
    final tone = _resolveTone();
    return _edit.isNeutral &&
        !tone.isLutTone &&
        tone.id == 'standard' &&
        (_stockEffects || _film.isNeutral);
  }

  void _scheduleRender() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _render);
  }

  void _update(PhotoEdit next) {
    setState(() => _edit = next);
    _scheduleRender();
  }

  void _updateFilm(FilmLook next) {
    setState(() => _film = next);
    _scheduleRender();
  }

  Future<void> _render() async {
    final original = _original;
    if (original == null) return;

    final token = ++_renderToken;
    if (_previewIsNeutral) {
      setState(() {
        _preview = original;
        _rendering = false;
        _renderError = null;
      });
      return;
    }

    setState(() => _rendering = true);
    try {
      final repository = ref.read(photoEditorRepositoryProvider);
      final bytes = await repository.renderPreview(
        path: widget.args.path,
        isVideo: _isVideo,
        payload: _payload(),
        maxDimension: 1400,
      );
      if (!mounted || token != _renderToken) return;
      setState(() {
        _preview = bytes;
        _rendering = false;
        _renderError = null;
      });
    } catch (error) {
      if (!mounted || token != _renderToken) return;
      setState(() {
        _rendering = false;
        _renderError = _describe(error);
      });
    }
  }

  Future<void> _openSaveSheet() async {
    if (_exporting) return;
    final choice = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppTheme.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.save_alt_rounded,
                    color: AppTheme.cinemaAmber,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isVideo ? 'Simpan video hasil edit' : 'Simpan foto hasil edit',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: AppTheme.textPrimary,
              ),
              title: const Text(
                'Simpan ke Galeri CineLens',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
              subtitle: const Text(
                'Hasil edit tersimpan di galeri aplikasi.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
              ),
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: AppTheme.cinemaAmber,
              ),
              title: const Text(
                'Galeri CineLens + Apple Photos',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
              subtitle: const Text(
                'Juga menyalin hasil edit ke aplikasi Photos.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
              ),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;
    await _export(toPhotos: choice);
  }

  Future<void> _export({required bool toPhotos}) async {
    setState(() {
      _exporting = true;
      _error = null;
    });

    try {
      final repository = ref.read(photoEditorRepositoryProvider);
      final camera = ref.read(cinemaCameraRepositoryProvider);
      final tone = _resolveTone();
      final toneName = tone.id == 'standard' ? 'Standar' : tone.name;
      final payload = _payload();

      if (_isVideo) {
        final path = await repository.exportVideo(
          path: widget.args.path,
          payload: payload,
          fps: 30,
        );
        final media = await camera.storeVideo(
          sourcePath: path,
          toneId: tone.id,
          toneName: toneName,
          intensity: _toneIntensity,
          isAnamorphic: false,
        );
        if (toPhotos) {
          try {
            await camera.saveVideoToGallery(media.path);
          } catch (_) {
            // The gallery copy already exists; Photos is best effort.
          }
        }
      } else {
        final bytes = await repository.exportPhoto(
          path: widget.args.path,
          payload: payload,
        );
        await camera.storePhoto(
          jpegBytes: bytes,
          toneId: tone.id,
          toneName: toneName,
          intensity: _toneIntensity,
          isAnamorphic: false,
        );
        if (toPhotos) {
          try {
            await camera.saveImageToIosGallery(bytes);
          } catch (_) {
            // Same: never lose the edited still because Photos said no.
          }
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _error = _describe(error);
      });
    }
  }

  void _resetAll() {
    setState(() {
      _edit = PhotoEdit.neutral;
      _film = _neutralFilm;
      _toneId = 'standard';
      _toneIntensity = 1.0;
      _stockEffects = true;
      _renderError = null;
    });
    _scheduleRender();
  }

  String _describe(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () {
            if (_exporting) return;
            context.pop();
          },
        ),
        title: Text(_isVideo ? 'EDIT VIDEO' : 'EDIT FOTO'),
        actions: [
          IconButton(
            tooltip: 'Reset semua',
            icon: const Icon(Icons.restart_alt_rounded),
            onPressed: _exporting ? null : _resetAll,
          ),
          IconButton(
            tooltip: 'Simpan',
            icon: const Icon(Icons.check_rounded),
            onPressed: _exporting || _original == null ? null : _openSaveSheet,
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(child: _buildBody()),
          if (_exporting) _buildExportOverlay(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppTheme.cinemaAmber),
      );
    }
    if (_original == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                _error ?? 'Media tidak dapat dibuka.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              EditorPrimaryButton(
                label: 'Coba lagi',
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _load();
                },
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Expanded(child: _buildPreview()),
        if (_renderError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Pratinjau gagal: $_renderError',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 10),
            ),
          ),
        _buildPanel(),
      ],
    );
  }

  Widget _buildPreview() {
    final image = _showOriginal ? _original : (_preview ?? _original);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            Image.memory(image, fit: BoxFit.contain, gaplessPlayback: true),
          if (_isVideo)
            Positioned(
              left: 8,
              top: 8,
              child: _chip('PRATINJAU FRAME PERTAMA'),
            ),
          if (_rendering)
            const Positioned(
              right: 10,
              top: 10,
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.cinemaAmber,
                ),
              ),
            ),
          Positioned(
            left: 8,
            bottom: 8,
            child: GestureDetector(
              onTapDown: (_) => setState(() => _showOriginal = true),
              onTapUp: (_) => setState(() => _showOriginal = false),
              onTapCancel: () => setState(() => _showOriginal = false),
              child: _chip('TAHAN: LIHAT ASLI'),
            ),
          ),
          if (_showOriginal)
            Positioned(
              right: 10,
              bottom: 8,
              child: _chip('ASLI'),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 8,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _buildPanel() {
    return Container(
      height: 306,
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _tabLabels.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final selected = index == _tab;
                return GestureDetector(
                  onTap: () => setState(() => _tab = index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppTheme.cinemaAmber.withValues(alpha: 0.18)
                          : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: selected
                            ? AppTheme.cinemaAmber
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _tabIcons[index],
                          size: 14,
                          color: selected
                              ? AppTheme.cinemaAmber
                              : AppTheme.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _tabLabels[index],
                          style: TextStyle(
                            color: selected
                                ? AppTheme.cinemaAmber
                                : AppTheme.textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            height: 1,
            color: Colors.white.withValues(alpha: 0.06),
          ),
          Expanded(child: _buildTabContent()),
        ],
      ),
    );
  }

  Widget _buildTabContent() {
    return switch (_tab) {
      0 => _buildLightTab(),
      1 => _buildColorTab(),
      2 => _buildCurveTab(),
      3 => _buildMixTab(),
      4 => _buildFilmTab(),
      5 => _buildEffectsTab(),
      _ => _buildDetailTab(),
    };
  }

  Widget _scroll(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: children,
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _buildLightTab() {
    return _scroll([
      EditSlider(
        label: 'Exposure',
        value: _edit.exposure,
        min: -2,
        max: 2,
        format: EditValueFormat.exposure,
        onChanged: (value) => _update(_edit.copyWith(exposure: value)),
      ),
      EditSlider(
        label: 'Contrast',
        value: _edit.contrast,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(contrast: value)),
      ),
      EditSlider(
        label: 'Highlights',
        value: _edit.highlights,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(highlights: value)),
      ),
      EditSlider(
        label: 'Shadows',
        value: _edit.shadows,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(shadows: value)),
      ),
      EditSlider(
        label: 'Whites',
        value: _edit.whites,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(whites: value)),
      ),
      EditSlider(
        label: 'Blacks',
        value: _edit.blacks,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(blacks: value)),
      ),
    ]);
  }

  Widget _buildColorTab() {
    return _scroll([
      EditSlider(
        label: 'Suhu (warm â†” cool)',
        value: _edit.temperature,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(temperature: value)),
      ),
      EditSlider(
        label: 'Tint (green â†” magenta)',
        value: _edit.tint,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(tint: value)),
      ),
      EditSlider(
        label: 'Vibrance',
        value: _edit.vibrance,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(vibrance: value)),
      ),
      EditSlider(
        label: 'Saturation',
        value: _edit.saturation,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(saturation: value)),
      ),
    ]);
  }

  Widget _buildCurveTab() {
    final points = _edit.curveFor(_curveChannel);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              for (final channel in EditCurveChannel.values) ...[
                _channelChip(channel),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              TextButton(
                onPressed: () => _update(
                  _edit.withCurve(_curveChannel, const <CurvePoint>[]),
                ),
                child: const Text(
                  'Reset',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 6),
            child: ToneCurveEditor(
              points: points,
              channel: _curveChannel,
              onChanged: (next) =>
                  _update(_edit.withCurve(_curveChannel, next)),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            'Ketuk untuk tambah titik Â· geser untuk bentuk Â· tahan untuk hapus',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 9),
          ),
        ),
      ],
    );
  }

  Widget _channelChip(EditCurveChannel channel) {
    final selected = channel == _curveChannel;
    final tint = switch (channel) {
      EditCurveChannel.rgb => AppTheme.cinemaAmber,
      EditCurveChannel.red => const Color(0xFFFF6B6B),
      EditCurveChannel.green => const Color(0xFF7BE495),
      EditCurveChannel.blue => const Color(0xFF6BA8FF),
    };
    return GestureDetector(
      onTap: () => setState(() => _curveChannel = channel),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? tint.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? tint : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          channel.label,
          style: TextStyle(
            color: selected ? tint : AppTheme.textPrimary,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _buildMixTab() {
    final band = _edit.hsl[_hslBand];
    return Column(
      children: [
        SizedBox(
          height: 42,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            itemCount: _edit.hsl.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final selected = index == _hslBand;
              final color = _bandColors[index % _bandColors.length];
              return GestureDetector(
                onTap: () => setState(() => _hslBand = index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? color.withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color:
                          selected ? color : Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Text(
                    _edit.hsl[index].name,
                    style: TextStyle(
                      color: selected ? color : AppTheme.textPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 4),
            children: [
              EditSlider(
                label: 'Hue',
                value: band.hue,
                format: EditValueFormat.degrees,
                accent: _bandColors[_hslBand % _bandColors.length],
                onChanged: (value) =>
                    _update(_edit.withHslBand(_hslBand, band.copyWith(hue: value))),
              ),
              EditSlider(
                label: 'Saturasi',
                value: band.saturation,
                format: EditValueFormat.signed,
                accent: _bandColors[_hslBand % _bandColors.length],
                onChanged: (value) => _update(
                  _edit.withHslBand(_hslBand, band.copyWith(saturation: value)),
                ),
              ),
              EditSlider(
                label: 'Luminans',
                value: band.luminance,
                format: EditValueFormat.signed,
                accent: _bandColors[_hslBand % _bandColors.length],
                onChanged: (value) => _update(
                  _edit.withHslBand(_hslBand, band.copyWith(luminance: value)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilmTab() {
    final tone = _resolveTone();
    final manualEffects = !_stockEffects || tone.isLutTone;
    final tones = _tones();

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      children: [
        if (widget.args.bakedToneName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.cinemaAmber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppTheme.cinemaAmber.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                'Tone ${widget.args.bakedToneName} sudah menempel di file ini. '
                'Pilih Standard kalau tidak mau menumpuk dua tone.',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ToneSelectorStrip(
          tones: tones,
          selectedTone: tone,
          compact: false,
          showCustomCard: false,
          onOpenCustomCreator: () {},
          onToneSelected: (next) {
            setState(() {
              _toneId = next.id;
              if (next.id == 'standard') _toneIntensity = 1.0;
              if (next.isLutTone) _stockEffects = false;
            });
            _scheduleRender();
          },
        ),
        const SizedBox(height: 4),
        _sectionLabel('INTENSITAS TONE'),
        EditSlider(
          label: tone.isLutTone ? 'Mix LUT' : 'Intensitas',
          value: _toneIntensity,
          min: 0,
          max: 1,
          resetValue: 1,
          format: EditValueFormat.percent,
          onChanged: (value) {
            setState(() => _toneIntensity = value);
            _scheduleRender();
          },
        ),
        SwitchListTile(
          value: _stockEffects,
          dense: true,
          activeTrackColor: AppTheme.cinemaAmber.withValues(alpha: 0.5),
          activeThumbColor: AppTheme.cinemaAmber,
          title: const Text(
            'Efek bawaan stok',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
          ),
          subtitle: const Text(
            'Grain, halation, bloom, dan vignette asli dari tone. Matikan untuk mengatur manual.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 10),
          ),
          onChanged: tone.isLutTone
              ? null
              : (value) {
                  setState(() => _stockEffects = value);
                  _scheduleRender();
                },
        ),
        if (manualEffects) ...[
          _sectionLabel('EFEK FILM MANUAL'),
          EditSlider(
            label: 'Grain',
            value: _film.grain,
            min: 0,
            max: 1,
            resetValue: 0,
            format: EditValueFormat.percent,
            onChanged: (value) => _updateFilm(_film.copyWith(grain: value)),
          ),
          EditSlider(
            label: 'Ukuran grain',
            value: _film.grainSize,
            min: 0,
            max: 1,
            resetValue: 0,
            format: EditValueFormat.percent,
            onChanged: (value) => _updateFilm(_film.copyWith(grainSize: value)),
          ),
          EditSlider(
            label: 'Halation',
            value: _film.halation,
            min: 0,
            max: 1,
            resetValue: 0,
            format: EditValueFormat.percent,
            onChanged: (value) => _updateFilm(_film.copyWith(halation: value)),
          ),
          EditSlider(
            label: 'Bloom',
            value: _film.bloom,
            min: 0,
            max: 1,
            resetValue: 0,
            format: EditValueFormat.percent,
            onChanged: (value) => _updateFilm(_film.copyWith(bloom: value)),
          ),
          EditSlider(
            label: 'Vignette film',
            value: _film.vignette,
            min: 0,
            max: 1,
            resetValue: 0,
            format: EditValueFormat.percent,
            onChanged: (value) => _updateFilm(_film.copyWith(vignette: value)),
          ),
        ],
      ],
    );
  }

  Widget _buildEffectsTab() {
    return _scroll([
      EditSlider(
        label: 'Clarity',
        value: _edit.clarity,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(clarity: value)),
      ),
      EditSlider(
        label: 'Texture',
        value: _edit.texture,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(texture: value)),
      ),
      EditSlider(
        label: 'Dehaze',
        value: _edit.dehaze,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(dehaze: value)),
      ),
      EditSlider(
        label: 'Fade',
        value: _edit.fade,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(fade: value)),
      ),
      EditSlider(
        label: 'Vignette',
        value: _edit.vignette,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(vignette: value)),
      ),
      EditSlider(
        label: 'Grain',
        value: _edit.grain,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(grain: value)),
      ),
    ]);
  }

  Widget _buildDetailTab() {
    return _scroll([
      EditSlider(
        label: 'Sharpen',
        value: _edit.sharpen,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(sharpen: value)),
      ),
      EditSlider(
        label: 'Noise reduction',
        value: _edit.noiseReduction,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(noiseReduction: value)),
      ),
    ]);
  }

  Widget _buildExportOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.72),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppTheme.cinemaAmber),
              const SizedBox(height: 16),
              Text(
                _isVideo
                    ? 'Merender video hasil editâ€¦\nJangan tutup aplikasi.'
                    : 'Merender foto hasil editâ€¦',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small filled button that avoids importing Cupertino just for one control.
class EditorPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const EditorPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(backgroundColor: AppTheme.cinemaAmber),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}


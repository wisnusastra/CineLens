// lib/features/photo_editor/presentation/screens/photo_editor_screen.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../cinema_camera/domain/entities/captured_media.dart';
import '../../../cinema_camera/domain/entities/cinema_tone.dart';
import '../../../cinema_camera/domain/entities/film_look.dart';
import '../../../cinema_camera/presentation/providers/cinema_camera_provider.dart';
import '../../../cinema_camera/presentation/widgets/media_specs_sheet.dart';
import '../../../cinema_camera/presentation/widgets/tone_selector_strip.dart';
import '../../data/edit_clipboard_store.dart';
import '../../data/photo_editor_repository.dart';
import '../../domain/entities/photo_edit.dart';
import '../widgets/color_grading_wheel.dart';
import '../widgets/edit_slider.dart';
import '../widgets/histogram_overlay.dart';
import '../widgets/mask_overlay_painter.dart';
import '../widgets/split_compare_view.dart';
import '../widgets/tone_curve_editor.dart';
import '../widgets/watermark_frame_picker.dart';

class _EditorSnapshot {
  final PhotoEdit edit;
  final FilmLook film;
  final String toneId;
  final double toneIntensity;
  final bool stockEffects;

  const _EditorSnapshot({
    required this.edit,
    required this.film,
    required this.toneId,
    required this.toneIntensity,
    required this.stockEffects,
  });
}

/// Full Lightroom-class Pro editor for photos and clips opened from the
/// CineLens gallery — backed by the 16-bit half-float (`RGBAh`) Core Image
/// pipeline on iOS.
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

  static const List<IconData> _tabIcons = <IconData>[
    Icons.wb_sunny_outlined,
    Icons.show_chart_rounded,
    Icons.palette_outlined,
    Icons.grain_rounded,
    Icons.tonality_rounded,
    Icons.movie_filter_outlined,
    Icons.auto_fix_high_outlined,
    Icons.details_rounded,
    Icons.blur_circular_rounded,
    Icons.layers_outlined,
    Icons.crop_rotate_rounded,
    Icons.crop_free_rounded,
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

  static const List<({String label, double temp, double tint})> _wbPresets =
      <({String label, double temp, double tint})>[
    (label: 'Asli', temp: 0.0, tint: 0.0),
    (label: 'Daylight', temp: 0.06, tint: 0.0),
    (label: 'Berawan', temp: 0.22, tint: 0.04),
    (label: 'Teduh', temp: 0.36, tint: 0.06),
    (label: 'Tungsten', temp: -0.34, tint: -0.04),
    (label: 'Neon', temp: -0.14, tint: 0.22),
  ];

  static const List<String> _cropAspects = <String>[
    'original',
    '1:1',
    '4:5',
    '6:7',
    '3:4',
    '2:3',
    '16:9',
    '2.39:1',
    '65:24',
  ];

  static const List<({String id, String label})> _logProfiles =
      <({String id, String label})>[
    (id: 'rec709', label: 'Rec.709'),
    (id: 'apple_log', label: 'Apple Log'),
    (id: 'sony_slog3', label: 'S-Log3'),
    (id: 'dji_dlogm', label: 'D-Log M'),
    (id: 'canon_clog3', label: 'C-Log3'),
    (id: 'fuji_flog2', label: 'F-Log2'),
  ];

  Uint8List? _original;
  Uint8List? _preview;
  Map<String, dynamic> _scopes = const <String, dynamic>{};
  List<SavedEditPreset> _savedPresets = const <SavedEditPreset>[];

  bool _loading = true;
  bool _rendering = false;
  bool _autoToning = false;
  bool _matchingColor = false;
  bool _generatingMask = false;
  bool _exportingCube = false;
  bool _exporting = false;
  bool _showOriginal = false;
  bool _splitCompare = false;
  bool _showHistogram = true;
  String? _error;
  String? _renderError;

  double _videoDurationSeconds = 0.0;
  double _videoScrubSeconds = 0.0;
  Timer? _scrubDebounce;

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

  // Undo / Redo history (up to 40 steps, coalesced per render settle).
  final List<_EditorSnapshot> _undoStack = <_EditorSnapshot>[];
  final List<_EditorSnapshot> _redoStack = <_EditorSnapshot>[];
  _EditorSnapshot? _pendingUndoBase;

  int _tab = 0;
  EditCurveChannel _curveChannel = EditCurveChannel.rgb;
  int _hslBand = 0;
  int _gradingZone = 0; // 0 = Shadows, 1 = Midtones, 2 = Highlights
  bool _cdlMode = false; // false = 3-Way Wheels, true = ASC CDL
  String? _selectedMaskId;

  Timer? _debounce;
  int _renderToken = 0;
  final TextEditingController _signatureController = TextEditingController();

  bool get _isVideo => widget.args.isVideo;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPresets();
    _loadSignature();
  }

  Future<void> _loadSignature() async {
    final saved = await ref
        .read(cinemaCameraRepositoryProvider)
        .loadPhotographerSignature();
    if (!mounted || saved.isEmpty) return;
    _signatureController.text = saved;
    if (_edit.frameCustomText.isEmpty) {
      setState(() => _edit = _edit.copyWith(frameCustomText: saved));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrubDebounce?.cancel();
    _signatureController.dispose();
    super.dispose();
  }

  _EditorSnapshot _currentSnapshot() => _EditorSnapshot(
        edit: _edit,
        film: _film,
        toneId: _toneId,
        toneIntensity: _toneIntensity,
        stockEffects: _stockEffects,
      );

  void _captureUndoPoint({bool immediate = false}) {
    if (immediate) {
      _pushUndo(_currentSnapshot());
      _pendingUndoBase = null;
      return;
    }
    _pendingUndoBase ??= _currentSnapshot();
  }

  void _commitPendingUndo() {
    final base = _pendingUndoBase;
    if (base == null) return;
    _pendingUndoBase = null;
    _pushUndo(base);
  }

  void _pushUndo(_EditorSnapshot snapshot) {
    _undoStack.add(snapshot);
    if (_undoStack.length > 40) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void _undo() {
    _commitPendingUndo();
    if (_undoStack.isEmpty) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_currentSnapshot());
    setState(() {
      _edit = previous.edit;
      _film = previous.film;
      _toneId = previous.toneId;
      _toneIntensity = previous.toneIntensity;
      _stockEffects = previous.stockEffects;
      _ensureValidSelectedMask();
    });
    _scheduleRender(recordUndo: false);
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_currentSnapshot());
    setState(() {
      _edit = next.edit;
      _film = next.film;
      _toneId = next.toneId;
      _toneIntensity = next.toneIntensity;
      _stockEffects = next.stockEffects;
      _ensureValidSelectedMask();
    });
    _scheduleRender(recordUndo: false);
  }

  void _ensureValidSelectedMask() {
    if (_selectedMaskId != null &&
        !_edit.masks.any((m) => m.id == _selectedMaskId)) {
      _selectedMaskId = _edit.masks.isNotEmpty ? _edit.masks.first.id : null;
    }
  }

  SelectiveMask? get _selectedMask {
    if (_edit.masks.isEmpty) return null;
    for (final m in _edit.masks) {
      if (m.id == _selectedMaskId) return m;
    }
    return _edit.masks.first;
  }

  Future<void> _loadPresets() async {
    final presets = await EditClipboardStore.loadPresets();
    if (!mounted) return;
    setState(() => _savedPresets = presets);
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
        timestampSeconds: _videoScrubSeconds,
      );
      if (!mounted) return;
      setState(() {
        _original = original;
        _preview = original;
        _loading = false;
        _error = null;
      });
      unawaited(_refreshHistogram(original));
      if (_isVideo) {
        unawaited(_loadVideoDuration());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(error);
      });
    }
  }

  Future<void> _loadVideoDuration() async {
    final meta = await ref
        .read(cinemaCameraRepositoryProvider)
        .inspectMediaMetadata(widget.args.path, isVideo: true);
    final dur = (meta['durationSeconds'] as num?)?.toDouble() ?? 0.0;
    if (mounted && dur > 0.2) {
      setState(() => _videoDurationSeconds = dur);
    }
  }

  void _onVideoScrubChanged(double seconds) {
    setState(() => _videoScrubSeconds = seconds);
    _scrubDebounce?.cancel();
    _scrubDebounce = Timer(const Duration(milliseconds: 120), () async {
      try {
        final orig = await ref.read(photoEditorRepositoryProvider).loadPreview(
              path: widget.args.path,
              isVideo: true,
              maxDimension: 1400,
              timestampSeconds: _videoScrubSeconds,
            );
        if (!mounted) return;
        setState(() => _original = orig);
        await _render();
      } catch (_) {}
    });
  }

  Future<void> _generateAiMask(String target) async {
    if (_generatingMask) return;
    setState(() => _generatingMask = true);
    try {
      final maskPath = await ref
          .read(photoEditorRepositoryProvider)
          .generateAiMask(
            path: widget.args.path,
            isVideo: _isVideo,
            target: target,
          );
      if (!mounted) return;
      setState(() => _generatingMask = false);
      if (maskPath == null) {
        _toast('AI Mask unavailable on this media');
        return;
      }
      final isSky = target == 'sky';
      final index = _edit.masks.length + 1;
      final mask = SelectiveMask(
        id: 'ai_${DateTime.now().microsecondsSinceEpoch}',
        name: isSky ? 'Sky AI $index' : 'Subject AI $index',
        type: isSky ? 'ai_sky' : 'ai_subject',
        maskImagePath: maskPath,
        feather: 0.25,
        exposure: isSky ? -0.35 : 0.25,
      );
      _update(
        _edit.copyWith(masks: <SelectiveMask>[..._edit.masks, mask]),
        immediateUndo: true,
      );
      setState(() => _selectedMaskId = mask.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _generatingMask = false);
      _toast(_describe(error));
    }
  }

  Future<void> _exportCubeLut() async {
    if (_exportingCube) return;
    final s = AppStrings.of(context);
    setState(() => _exportingCube = true);
    try {
      final tone = _resolveTone();
      final title = tone.id == 'standard'
          ? 'CineLens_Grade'
          : 'CineLens_${tone.name.replaceAll(' ', '_')}';
      final cubePath = await ref
          .read(photoEditorRepositoryProvider)
          .exportCubeLut(payload: _payload(), title: title);
      if (!mounted) return;
      setState(() => _exportingCube = false);
      if (cubePath == null) {
        _toast('Failed to export .cube LUT');
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppTheme.surfaceDark,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (sheetCtx) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  s.exportCubeLut.toUpperCase(),
                  style: const TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.cinemaAmber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () async {
                    Navigator.of(sheetCtx).pop();
                    final ok = await ref
                        .read(cinemaCameraProvider.notifier)
                        .importCubeFromPath(cubePath);
                    if (mounted && ok) _toast(s.lutAddedToCamera);
                  },
                  icon: const Icon(Icons.camera_alt_rounded, size: 17),
                  label: Text(
                    s.useLutInCamera,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textPrimary,
                    side: const BorderSide(color: AppTheme.hairline),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () async {
                    Navigator.of(sheetCtx).pop();
                    await Share.shareXFiles(
                      [XFile(cubePath)],
                      subject: '$title.cube',
                    );
                  },
                  icon: const Icon(Icons.ios_share_rounded, size: 17),
                  label: Text(
                    s.shareCubeFile,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _exportingCube = false);
      _toast(_describe(error));
    }
  }

  Future<void> _refreshHistogram(Uint8List bytes) async {
    if (!_showHistogram) return;
    try {
      final scopes = await ref
          .read(photoEditorRepositoryProvider)
          .computeScopes(bytes);
      if (!mounted || scopes.isEmpty) return;
      setState(() => _scopes = scopes);
    } catch (_) {
      // Best effort; scopes are auxiliary.
    }
  }

  Future<void> _pickAndMatchReference() async {
    if (_matchingColor) return;
    final s = AppStrings.of(context);
    final media =
        await ref.read(cinemaCameraProvider.notifier).loadCapturedMedia();
    final photos =
        media.where((m) => !m.isVideo && m.path != widget.args.path).toList();
    if (!mounted) return;
    if (photos.isEmpty) {
      _toast(s.noReferencePhotos);
      return;
    }

    final selected = await showModalBottomSheet<CapturedMedia>(
      context: context,
      backgroundColor: AppTheme.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: SizedBox(
          height: 360,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.colorize_rounded,
                      color: AppTheme.cinemaAmber,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      s.pickReferenceTitle,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(6),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (_, idx) {
                    final item = photos[idx];
                    return GestureDetector(
                      onTap: () => Navigator.of(sheetCtx).pop(item),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.file(
                          File(item.path),
                          fit: BoxFit.cover,
                          cacheWidth: 260,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;

    setState(() => _matchingColor = true);
    try {
      final result = await ref.read(photoEditorRepositoryProvider).matchColor(
            sourcePath: widget.args.path,
            isVideo: _isVideo,
            referencePath: selected.path,
          );
      if (!mounted) return;
      setState(() => _matchingColor = false);
      if (result.isEmpty) return;

      List<double> readTriple(String key, List<double> fallback) {
        final raw = result[key];
        if (raw is List && raw.length >= 3) {
          return raw.take(3).map((e) => (e as num).toDouble()).toList();
        }
        return fallback;
      }

      final slope = readTriple('cdlSlope', _edit.cdlSlope);
      final offset = readTriple('cdlOffset', _edit.cdlOffset);
      final power = readTriple('cdlPower', _edit.cdlPower);
      final sat = (result['cdlSaturation'] as num?)?.toDouble() ??
          _edit.cdlSaturation;
      _update(
        _edit.copyWith(
          cdlSlope: slope,
          cdlOffset: offset,
          cdlPower: power,
          cdlSaturation: sat,
        ),
        immediateUndo: true,
      );
      _toast(s.colorMatched);
    } catch (error) {
      if (!mounted) return;
      setState(() => _matchingColor = false);
      _toast(_describe(error));
    }
  }

  Map<String, dynamic> _payload() {
    final tone = _resolveTone();
    final editMap = _edit.toParameters();
    if ((editMap['frameCustomText'] as String? ?? '').isEmpty &&
        tone.id != 'standard') {
      editMap['frameCustomText'] = tone.name;
    }
    final payload = <String, dynamic>{
      'edit': editMap,
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

  void _scheduleRender({bool recordUndo = true}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), () {
      if (recordUndo) _commitPendingUndo();
      _render();
    });
  }

  void _update(PhotoEdit next, {bool immediateUndo = false}) {
    _captureUndoPoint(immediate: immediateUndo);
    setState(() => _edit = next);
    _scheduleRender(recordUndo: !immediateUndo);
  }

  void _updateFilm(FilmLook next) {
    _captureUndoPoint();
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
      unawaited(_refreshHistogram(original));
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
        timestampSeconds: _videoScrubSeconds,
      );
      if (!mounted || token != _renderToken) return;
      setState(() {
        _preview = bytes;
        _rendering = false;
        _renderError = null;
      });
      unawaited(_refreshHistogram(bytes));
    } catch (error) {
      if (!mounted || token != _renderToken) return;
      setState(() {
        _rendering = false;
        _renderError = _describe(error);
      });
    }
  }

  Future<void> _applyAutoTone() async {
    if (_autoToning || _original == null) return;
    setState(() => _autoToning = true);
    try {
      final result = await ref.read(photoEditorRepositoryProvider).autoTone(
            path: widget.args.path,
            isVideo: _isVideo,
          );
      if (!mounted) return;
      setState(() => _autoToning = false);
      if (result.isEmpty) {
        _toast('Auto Tone hanya tersedia di aplikasi iOS.');
        return;
      }
      _update(
        _edit.copyWith(
          exposure: result['exposure'] ?? _edit.exposure,
          contrast: result['contrast'] ?? _edit.contrast,
          highlights: result['highlights'] ?? _edit.highlights,
          shadows: result['shadows'] ?? _edit.shadows,
          whites: result['whites'] ?? _edit.whites,
          blacks: result['blacks'] ?? _edit.blacks,
          temperature: result['temperature'] ?? _edit.temperature,
          tint: result['tint'] ?? _edit.tint,
          vibrance: result['vibrance'] ?? _edit.vibrance,
        ),
        immediateUndo: true,
      );
      _toast('Auto Tone diterapkan.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _autoToning = false);
      _toast('Auto Tone gagal: ${_describe(error)}');
    }
  }

  void _copySettings() {
    EditClipboardStore.copy(
      CopiedEditSettings(
        edit: _edit,
        toneId: _toneId,
        toneIntensity: _toneIntensity,
        stockEffects: _stockEffects,
        film: _film,
      ),
    );
    _toast('Setelan edit disalin (Copy Settings).');
  }

  void _pasteSettings() {
    final copied = EditClipboardStore.clipboard;
    if (copied == null) {
      _toast('Belum ada setelan edit yang disalin.');
      return;
    }
    _captureUndoPoint(immediate: true);
    setState(() {
      _edit = copied.edit;
      _toneId = copied.toneId;
      _toneIntensity = copied.toneIntensity;
      _stockEffects = copied.stockEffects;
      _film = copied.film;
      _ensureValidSelectedMask();
    });
    _scheduleRender(recordUndo: false);
    _toast('Setelan edit ditempel (Paste Settings).');
  }

  Future<void> _promptSavePreset() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text(
          'Simpan Preset Edit',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 15),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Misal: Street Moody / Warm Portrait',
            hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Batal', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.cinemaAmber),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Simpan', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;

    final preset = SavedEditPreset(
      id: 'edit_preset_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      edit: _edit,
      toneId: _toneId,
      toneIntensity: _toneIntensity,
      stockEffects: _stockEffects,
    );
    final updated = await EditClipboardStore.savePreset(preset);
    if (!mounted) return;
    setState(() => _savedPresets = updated);
    _toast('Preset "$name" tersimpan di tab Film.');
  }

  void _applySavedPreset(SavedEditPreset preset) {
    _captureUndoPoint(immediate: true);
    setState(() {
      _edit = preset.edit;
      _toneId = preset.toneId;
      _toneIntensity = preset.toneIntensity;
      _stockEffects = preset.stockEffects;
      _ensureValidSelectedMask();
    });
    _scheduleRender(recordUndo: false);
    _toast('Preset "${preset.name}" diterapkan.');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontSize: 12)),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _openSaveSheet() async {
    if (_exporting) return;
    final s = AppStrings.of(context);
    final choice = await showModalBottomSheet<({bool toPhotos, String social})>(
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
                    size: 19,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    s.save,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.photo_library_outlined,
                color: AppTheme.textPrimary,
              ),
              title: Text(
                s.saveToGalleryOnly,
                style:
                    const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
              onTap: () => Navigator.of(sheetContext)
                  .pop((toPhotos: false, social: 'none')),
            ),
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: AppTheme.cinemaAmber,
              ),
              title: Text(
                s.saveToGalleryAndPhotos,
                style:
                    const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
              onTap: () => Navigator.of(sheetContext)
                  .pop((toPhotos: true, social: 'none')),
            ),
            if (!_isVideo) ...[
              const Divider(color: AppTheme.hairline, height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '1-TAP SOCIAL EXPORT (SAFE sRGB)',
                    style: AppTheme.monoStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    for (final item in const <(String, String)>[
                      ('ig_4_5', 'IG 4:5'),
                      ('reels_9_16', 'REELS 9:16'),
                      ('wa_hd', 'WA HD'),
                    ])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.cinemaAmber,
                              side: BorderSide(
                                color: AppTheme.cinemaAmber
                                    .withValues(alpha: 0.45),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onPressed: () => Navigator.of(sheetContext)
                                .pop((toPhotos: true, social: item.$1)),
                            child: Text(
                              item.$2,
                              style: AppTheme.monoStyle(
                                color: AppTheme.cinemaAmber,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 6),
          ],
        ),
      ),
    );

    if (choice == null || !mounted) return;
    await _export(toPhotos: choice.toPhotos, socialPreset: choice.social);
  }

  Future<void> _export({
    required bool toPhotos,
    String socialPreset = 'none',
  }) async {
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
        final nativeSavesHeif10 = _edit.heif10Bit && socialPreset == 'none';
        final bytes = await repository.exportPhoto(
          path: widget.args.path,
          payload: payload,
          socialPreset: socialPreset,
          saveToPhotos: toPhotos,
        );
        await camera.storePhoto(
          jpegBytes: bytes,
          toneId: tone.id,
          toneName: toneName,
          intensity: _toneIntensity,
          isAnamorphic: false,
        );
        // When native Swift already saved the 10-bit Display P3 `.heic` (with
        // automatic JPEG fallback), skip the duplicate 8-bit JPEG Photos save!
        if (toPhotos && !nativeSavesHeif10) {
          try {
            await camera.saveImageToIosGallery(bytes);
          } catch (_) {
            // Never lose the edited still because Photos refused.
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
    _captureUndoPoint(immediate: true);
    setState(() {
      _edit = PhotoEdit.neutral;
      _film = _neutralFilm;
      _toneId = 'standard';
      _toneIntensity = 1.0;
      _stockEffects = true;
      _selectedMaskId = null;
      _renderError = null;
    });
    _scheduleRender(recordUndo: false);
  }

  String _describe(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundBlack,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () {
            if (_exporting) return;
            context.pop();
          },
        ),
        title: Text(
          _isVideo ? s.editVideo : s.editPhoto,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: s.undo,
            icon: Icon(
              Icons.undo_rounded,
              size: 19,
              color: _undoStack.isNotEmpty ? Colors.white : Colors.white24,
            ),
            onPressed: _exporting || _undoStack.isEmpty ? null : _undo,
          ),
          IconButton(
            tooltip: s.redo,
            icon: Icon(
              Icons.redo_rounded,
              size: 19,
              color: _redoStack.isNotEmpty ? Colors.white : Colors.white24,
            ),
            onPressed: _exporting || _redoStack.isEmpty ? null : _redo,
          ),
          IconButton(
            tooltip: s.auto,
            icon: _autoToning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.cinemaAmber,
                    ),
                  )
                : const Icon(
                    Icons.auto_awesome_rounded,
                    size: 19,
                    color: AppTheme.cinemaAmber,
                  ),
            onPressed: _exporting || _autoToning || _original == null
                ? null
                : _applyAutoTone,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
            color: AppTheme.surfaceDark,
            onSelected: (value) {
              switch (value) {
                case 'copy':
                  _copySettings();
                case 'paste':
                  _pasteSettings();
                case 'save_preset':
                  _promptSavePreset();
                case 'export_cube':
                  _exportCubeLut();
                case 'media_info':
                  showMediaSpecsSheet(
                    context,
                    ref,
                    path: widget.args.path,
                    isVideo: _isVideo,
                  );
                case 'histogram':
                  setState(() => _showHistogram = !_showHistogram);
                  if (_showHistogram && (_preview ?? _original) != null) {
                    unawaited(_refreshHistogram((_preview ?? _original)!));
                  }
                case 'split':
                  setState(() => _splitCompare = !_splitCompare);
                case 'reset':
                  _resetAll();
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem(
                value: 'copy',
                child: Text(
                  s.copySettings,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              PopupMenuItem(
                value: 'paste',
                enabled: EditClipboardStore.hasClipboard,
                child: Text(
                  s.pasteSettings,
                  style: TextStyle(
                    color: EditClipboardStore.hasClipboard
                        ? Colors.white
                        : Colors.white38,
                    fontSize: 12,
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'save_preset',
                child: Text(
                  s.savePreset,
                  style: const TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 12,
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'export_cube',
                child: Text(
                  s.exportCubeLut,
                  style: const TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 12,
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'media_info',
                child: Text(
                  s.mediaInfo,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'histogram',
                child: Text(
                  '${s.cycleScope} (${_showHistogram ? s.on : s.off})',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              PopupMenuItem(
                value: 'split',
                child: Text(
                  s.toggleSplit,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'reset',
                child: Text(
                  s.resetAll,
                  style: const TextStyle(
                    color: AppTheme.cinemaRed,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: GestureDetector(
              onTap: _exporting || _original == null ? null : _openSaveSheet,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 11),
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.cinemaAmber,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  s.save,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
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
        if (_isVideo && _videoDurationSeconds > 0.2) _buildVideoScrubBar(),
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

  Widget _buildVideoScrubBar() {
    String fmt(double sec) {
      final total = sec.round().clamp(0, 35999);
      final m = (total ~/ 60).toString().padLeft(2, '0');
      final s = (total % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Text(
            fmt(_videoScrubSeconds),
            style: AppTheme.monoStyle(
              color: AppTheme.cinemaAmber,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  activeTrackColor: AppTheme.cinemaAmber,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: AppTheme.cinemaAmber,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 11),
                ),
                child: Slider(
                  value: _videoScrubSeconds.clamp(0.0, _videoDurationSeconds),
                  min: 0.0,
                  max: _videoDurationSeconds,
                  onChanged: _onVideoScrubChanged,
                ),
              ),
            ),
          ),
          Text(
            fmt(_videoDurationSeconds),
            style: AppTheme.monoStyle(
              color: AppTheme.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final original = _original;
    final edited = _preview ?? original;
    final showMaskGuide = _tab == 9 &&
        _selectedMask != null &&
        !_selectedMask!.isAiMask &&
        !_splitCompare;
    final showBlurGuide =
        _tab == 8 && _edit.blurAmount > 0.005 && !_splitCompare;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_splitCompare && original != null && edited != null)
            SplitCompareView(original: original, edited: edited)
          else if ((_showOriginal ? original : edited) != null)
            InteractiveViewer(
              minScale: 1.0,
              maxScale: 5.0,
              panEnabled: !showMaskGuide && !showBlurGuide,
              child: Image.memory(
                (_showOriginal ? original : edited)!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),

          if (showMaskGuide || showBlurGuide)
            EditorInteractiveOverlay(
              activeMask: showMaskGuide ? _selectedMask : null,
              onMaskChanged: (updated) => _update(_edit.withMaskUpdated(updated)),
              showBlurTarget: showBlurGuide,
              blurStyle: _edit.blurStyle,
              blurCenterX: _edit.blurCenterX,
              blurCenterY: _edit.blurCenterY,
              blurRadius: _edit.blurRadius,
              onBlurCenterChanged: (cx, cy) =>
                  _update(_edit.copyWith(blurCenterX: cx, blurCenterY: cy)),
            ),

          if (_showHistogram && _scopes.isNotEmpty && !_splitCompare)
            Positioned(
              left: 8,
              top: 8,
              child: HistogramOverlay(histogram: _scopes),
            ),

          if (_isVideo && !_splitCompare)
            Positioned(
              left: 8,
              top: _showHistogram && _scopes.isNotEmpty ? 80 : 8,
              child: _chip('VIDEO'),
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

          if (!_splitCompare)
            Positioned(
              left: 8,
              bottom: 8,
              child: GestureDetector(
                onTapDown: (_) => setState(() => _showOriginal = true),
                onTapUp: (_) => setState(() => _showOriginal = false),
                onTapCancel: () => setState(() => _showOriginal = false),
                child: _chip(AppStrings.of(context).holdOriginal),
              ),
            ),

          Positioned(
            right: 8,
            bottom: 8,
            child: GestureDetector(
              onTap: () => setState(() => _splitCompare = !_splitCompare),
              child: _chip(
                AppStrings.of(context).splitCompare,
                active: _splitCompare,
              ),
            ),
          ),

          if (_showOriginal && !_splitCompare)
            Positioned(
              right: 10,
              top: 10,
              child: _chip(AppStrings.of(context).original, active: true),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, {bool active = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: active
            ? AppTheme.cinemaAmber.withValues(alpha: 0.9)
            : Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: active
              ? AppTheme.cinemaAmber
              : Colors.white.withValues(alpha: 0.14),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.black : Colors.white70,
          fontSize: 8,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _buildPanel() {
    final s = AppStrings.of(context);
    final localizedTabs = <String>[
      s.tabLight,
      s.tabCurve,
      s.tabColor,
      s.tabMix,
      s.tabGrade,
      s.tabFilm,
      s.tabFx,
      s.tabDetail,
      s.tabBlur,
      s.tabMask,
      s.tabCrop,
      'Watermark',
    ];

    return Container(
      height: 318,
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
              itemCount: localizedTabs.length,
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
                          localizedTabs[index],
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
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 190),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.03),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey<int>(_tab),
                child: _buildTabContent(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabContent() {
    return switch (_tab) {
      0 => _buildLightTab(),
      1 => _buildCurveTab(),
      2 => _buildColorTab(),
      3 => _buildMixTab(),
      4 => _buildColorGradingTab(),
      5 => _buildFilmTab(),
      6 => _buildEffectsTab(),
      7 => _buildDetailTab(),
      8 => _buildLensBlurTab(),
      9 => _buildMaskingTab(),
      10 => _buildOpticsCropTab(),
      _ => _buildWatermarkTab(),
    };
  }

  Widget _buildWatermarkTab() {
    final s = AppStrings.of(context);
    return _scroll([
      const SizedBox(height: 6),
      WatermarkFramePicker(
        selectedStyle: _edit.frameStyle,
        selectedTheme: _edit.frameTheme,
        onStyleChanged: (id) => _update(
          _edit.copyWith(frameStyle: id),
          immediateUndo: true,
        ),
        onThemeChanged: (theme) => _update(
          _edit.copyWith(frameTheme: theme),
          immediateUndo: true,
        ),
      ),
      const SizedBox(height: 8),
      if (_edit.frameStyle != 'none') ...[
        SwitchListTile(
          dense: true,
          value: _edit.frameExifCaption,
          activeThumbColor: AppTheme.cinemaAmber,
          title: Text(
            s.exifCaption,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
          ),
          onChanged: (v) => _update(
            _edit.copyWith(frameExifCaption: v),
            immediateUndo: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _signatureController,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Signature (mis. WISNU SASTRA)',
                    hintStyle: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11.5,
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.hairline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: AppTheme.cinemaAmber),
                    ),
                  ),
                  onChanged: (v) => _update(
                    _edit.copyWith(frameCustomText: v.trim()),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.cinemaAmber,
                  side: BorderSide(
                    color: AppTheme.cinemaAmber.withValues(alpha: 0.5),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  minimumSize: Size.zero,
                ),
                onPressed: () async {
                  final text = _signatureController.text.trim();
                  await ref
                      .read(cinemaCameraRepositoryProvider)
                      .savePhotographerSignature(text);
                  _update(
                    _edit.copyWith(frameCustomText: text),
                    immediateUndo: true,
                  );
                  if (!mounted) return;
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Signature default disimpan.',
                          style: TextStyle(fontSize: 12),
                        ),
                        backgroundColor: AppTheme.cardDark,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                },
                child: const Text(
                  'SAVE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      SwitchListTile(
        dense: true,
        value: _edit.frameDateStamp,
        activeThumbColor: AppTheme.cinemaAmber,
        title: Text(
          s.dateStamp,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
        ),
        onChanged: (v) => _update(
          _edit.copyWith(frameDateStamp: v),
          immediateUndo: true,
        ),
      ),
      if (!_isVideo)
        SwitchListTile(
          dense: true,
          value: _edit.heif10Bit,
          activeThumbColor: AppTheme.cinemaAmber,
          title: Text(
            s.heif10Bit,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
          ),
          onChanged: (v) => _update(
            _edit.copyWith(heif10Bit: v),
            immediateUndo: true,
          ),
        ),
    ]);
  }

  Widget _scroll(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: children,
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
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

  // ------------------------------------------------------------------ 0. LIGHT
  Widget _buildLightTab() {
    return _scroll([
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Row(
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.cinemaAmber,
                side: const BorderSide(color: AppTheme.cinemaAmber),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _autoToning ? null : _applyAutoTone,
              icon: const Icon(Icons.auto_awesome_rounded, size: 14),
              label: const Text(
                'AUTO TONE',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Ketuk 2× nama slider untuk reset cepat',
                style: TextStyle(color: Colors.white38, fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
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
      EditSlider(
        label: AppStrings.of(context).filmicRollOff,
        value: _edit.filmicRollOff,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(filmicRollOff: value)),
      ),
    ]);
  }

  // ------------------------------------------------------------------ 1. CURVE
  Widget _buildCurveTab() {
    final points = _edit.curveFor(_curveChannel);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 2),
          child: Row(
            children: [
              for (final channel in EditCurveChannel.values) ...[
                _channelChip(channel),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              _miniActionChip(
                'S-Halus',
                onTap: () => _update(
                  _edit.withCurve(_curveChannel, const <CurvePoint>[
                    CurvePoint(0, 0),
                    CurvePoint(0.25, 0.21),
                    CurvePoint(0.75, 0.79),
                    CurvePoint(1, 1),
                  ]),
                  immediateUndo: true,
                ),
              ),
              const SizedBox(width: 4),
              _miniActionChip(
                'Matte',
                onTap: () => _update(
                  _edit.withCurve(_curveChannel, const <CurvePoint>[
                    CurvePoint(0, 0.08),
                    CurvePoint(0.22, 0.20),
                    CurvePoint(0.78, 0.80),
                    CurvePoint(1, 0.96),
                  ]),
                  immediateUndo: true,
                ),
              ),
              const SizedBox(width: 4),
              _miniActionChip(
                'Reset',
                onTap: () => _update(
                  _edit.withCurve(_curveChannel, const <CurvePoint>[]),
                  immediateUndo: true,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 4),
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
            'Ketuk untuk tambah titik · geser untuk bentuk · tahan untuk hapus',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 9),
          ),
        ),
      ],
    );
  }

  Widget _miniActionChip(String label, {required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
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

  // ------------------------------------------------------------------ 2. COLOR
  Widget _buildColorTab() {
    return _scroll([
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Row(
          children: [
            FilterChip(
              label: const Text(
                'B&W',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
              ),
              selected: _edit.blackAndWhite,
              selectedColor: AppTheme.cinemaAmber,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              labelStyle: TextStyle(
                color: _edit.blackAndWhite ? Colors.black : Colors.white,
              ),
              onSelected: (v) =>
                  _update(_edit.copyWith(blackAndWhite: v), immediateUndo: true),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _wbPresets.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, idx) {
                    final preset = _wbPresets[idx];
                    return ActionChip(
                      label: Text(
                        preset.label,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      padding: EdgeInsets.zero,
                      onPressed: () => _update(
                        _edit.copyWith(
                          temperature: preset.temp,
                          tint: preset.tint,
                        ),
                        immediateUndo: true,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      EditSlider(
        label: 'Suhu (Warm ↔ Cool)',
        value: _edit.temperature,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(temperature: value)),
      ),
      EditSlider(
        label: 'Tint (Green ↔ Magenta)',
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
      EditSlider(
        label: AppStrings.of(context).colorDensity,
        value: _edit.colorDensity,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(colorDensity: value)),
      ),
      EditSlider(
        label: AppStrings.of(context).skinProtect,
        value: _edit.skinProtection,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(skinProtection: value)),
      ),
    ]);
  }

  // ------------------------------------------------------------------ 3. MIX
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
              final active = !_edit.hsl[index].isNeutral;
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
                      color: selected
                          ? color
                          : Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    children: [
                      if (active) ...[
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        _edit.hsl[index].name,
                        style: TextStyle(
                          color: selected ? color : AppTheme.textPrimary,
                          fontSize: 10,
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
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 4),
            children: [
              EditSlider(
                label: 'Hue',
                value: band.hue,
                format: EditValueFormat.degrees,
                accent: _bandColors[_hslBand % _bandColors.length],
                onChanged: (value) => _update(
                  _edit.withHslBand(_hslBand, band.copyWith(hue: value)),
                ),
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
                label: _edit.blackAndWhite
                    ? 'Luminans (B&W Mix)'
                    : 'Luminans',
                value: band.luminance,
                format: EditValueFormat.signed,
                accent: _bandColors[_hslBand % _bandColors.length],
                onChanged: (value) => _update(
                  _edit.withHslBand(_hslBand, band.copyWith(luminance: value)),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: TextButton(
                    onPressed: band.isNeutral
                        ? null
                        : () => _update(
                              _edit.withHslBand(
                                _hslBand,
                                HslBand(name: band.name),
                              ),
                              immediateUndo: true,
                            ),
                    child: Text(
                      'Reset ${band.name}',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- 4. GRADING
  Widget _buildColorGradingTab() {
    final s = AppStrings.of(context);
    final cg = _edit.colorGrading;
    final zoneNames = const <String>['Shadows', 'Midtones', 'Highlights'];
    final activeWheel = switch (_gradingZone) {
      0 => cg.shadows,
      1 => cg.midtones,
      _ => cg.highlights,
    };

    void updateWheel(ColorWheelGrade next) {
      final updated = switch (_gradingZone) {
        0 => cg.copyWith(shadows: next),
        1 => cg.copyWith(midtones: next),
        _ => cg.copyWith(highlights: next),
      };
      _update(_edit.copyWith(colorGrading: updated));
    }

    Widget modeSwitcher = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          for (final entry in [(false, s.wheelsMode), (true, s.cdlMode)]) ...[
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _cdlMode = entry.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _cdlMode == entry.$1
                        ? AppTheme.cinemaAmber
                        : AppTheme.cardDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _cdlMode == entry.$1
                          ? AppTheme.cinemaAmber
                          : AppTheme.hairline,
                    ),
                  ),
                  child: Text(
                    entry.$2,
                    style: TextStyle(
                      color:
                          _cdlMode == entry.$1 ? Colors.black : Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.7,
                    ),
                  ),
                ),
              ),
            ),
            if (!entry.$1) const SizedBox(width: 8),
          ],
        ],
      ),
    );

    if (_cdlMode) {
      List<double> setChannel(List<double> src, int idx, double v) {
        final copy = List<double>.from(src);
        while (copy.length < 3) {
          copy.add(0.0);
        }
        copy[idx] = v;
        return copy;
      }

      String fmtCdl(double v) => v.toStringAsFixed(2);

      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          modeSwitcher,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ASC CDL · SLOPE / OFFSET / POWER',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.9,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _update(
                    _edit.copyWith(
                      cdlSlope: const [1.0, 1.0, 1.0],
                      cdlOffset: const [0.0, 0.0, 0.0],
                      cdlPower: const [1.0, 1.0, 1.0],
                      cdlSaturation: 1.0,
                    ),
                    immediateUndo: true,
                  ),
                  child: Text(
                    s.reset,
                    style: const TextStyle(
                      color: AppTheme.cinemaAmber,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          EditSlider(
            label: 'Slope R',
            value: _edit.cdlSlope[0],
            min: 0.4,
            max: 1.8,
            resetValue: 1.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlSlope: setChannel(_edit.cdlSlope, 0, v))),
          ),
          EditSlider(
            label: 'Slope G',
            value: _edit.cdlSlope[1],
            min: 0.4,
            max: 1.8,
            resetValue: 1.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlSlope: setChannel(_edit.cdlSlope, 1, v))),
          ),
          EditSlider(
            label: 'Slope B',
            value: _edit.cdlSlope[2],
            min: 0.4,
            max: 1.8,
            resetValue: 1.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlSlope: setChannel(_edit.cdlSlope, 2, v))),
          ),
          EditSlider(
            label: 'Offset R',
            value: _edit.cdlOffset[0],
            min: -0.3,
            max: 0.3,
            resetValue: 0.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlOffset: setChannel(_edit.cdlOffset, 0, v))),
          ),
          EditSlider(
            label: 'Offset G',
            value: _edit.cdlOffset[1],
            min: -0.3,
            max: 0.3,
            resetValue: 0.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlOffset: setChannel(_edit.cdlOffset, 1, v))),
          ),
          EditSlider(
            label: 'Offset B',
            value: _edit.cdlOffset[2],
            min: -0.3,
            max: 0.3,
            resetValue: 0.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlOffset: setChannel(_edit.cdlOffset, 2, v))),
          ),
          EditSlider(
            label: 'Power R',
            value: _edit.cdlPower[0],
            min: 0.5,
            max: 1.8,
            resetValue: 1.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlPower: setChannel(_edit.cdlPower, 0, v))),
          ),
          EditSlider(
            label: 'Power G',
            value: _edit.cdlPower[1],
            min: 0.5,
            max: 1.8,
            resetValue: 1.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlPower: setChannel(_edit.cdlPower, 1, v))),
          ),
          EditSlider(
            label: 'Power B',
            value: _edit.cdlPower[2],
            min: 0.5,
            max: 1.8,
            resetValue: 1.0,
            format: fmtCdl,
            onChanged: (v) =>
                _update(_edit.copyWith(cdlPower: setChannel(_edit.cdlPower, 2, v))),
          ),
          EditSlider(
            label: 'CDL Saturation',
            value: _edit.cdlSaturation,
            min: 0.0,
            max: 2.0,
            resetValue: 1.0,
            format: fmtCdl,
            onChanged: (v) => _update(_edit.copyWith(cdlSaturation: v)),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        modeSwitcher,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (var i = 0; i < 3; i++) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _gradingZone = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _gradingZone == i
                            ? AppTheme.cinemaAmber.withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _gradingZone == i
                              ? AppTheme.cinemaAmber
                              : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Text(
                        zoneNames[i],
                        style: TextStyle(
                          color: _gradingZone == i
                              ? AppTheme.cinemaAmber
                              : Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
                if (i < 2) const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              ColorGradingWheel(
                grade: activeWheel,
                size: 126,
                onChanged: updateWheel,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${zoneNames[_gradingZone].toUpperCase()} WHEEL',
                      style: const TextStyle(
                        color: AppTheme.cinemaAmber,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Hue ${activeWheel.hue.round()}° · Sat ${(activeWheel.saturation * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Geser lingkaran untuk tint warna · ketuk 2× roda untuk reset.',
                      style: TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => updateWheel(ColorWheelGrade.neutral),
                      child: const Text(
                        'Reset Wheel Ini',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        EditSlider(
          label: 'Luminance (${zoneNames[_gradingZone]})',
          value: activeWheel.luminance,
          format: EditValueFormat.signed,
          onChanged: (v) => updateWheel(activeWheel.copyWith(luminance: v)),
        ),
        EditSlider(
          label: 'Blending',
          value: cg.blending,
          min: 0,
          max: 1,
          resetValue: 0.5,
          format: EditValueFormat.percent,
          onChanged: (v) =>
              _update(_edit.copyWith(colorGrading: cg.copyWith(blending: v))),
        ),
        EditSlider(
          label: 'Balance (Shadow ↔ Highlight)',
          value: cg.balance,
          format: EditValueFormat.signed,
          onChanged: (v) =>
              _update(_edit.copyWith(colorGrading: cg.copyWith(balance: v))),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 5. FILM
  Widget _buildFilmTab() {
    final s = AppStrings.of(context);
    final tone = _resolveTone();
    final manualEffects = !_stockEffects || tone.isLutTone;
    final tones = _tones();

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      children: [
        // OpenFilm Multi-Camera Log IDT + Shot-to-Shot Match Ref
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(
            children: [
              Text(
                s.inputLogProfile,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.cinemaAmber,
                  side: const BorderSide(color: AppTheme.cinemaAmber),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _matchingColor ? null : _pickAndMatchReference,
                icon: _matchingColor
                    ? const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: AppTheme.cinemaAmber,
                        ),
                      )
                    : const Icon(Icons.colorize_rounded, size: 13),
                label: Text(
                  s.matchReference,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.hairline),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _exportingCube ? null : _exportCubeLut,
                icon: _exportingCube
                    ? const SizedBox(
                        width: 11,
                        height: 11,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: AppTheme.cinemaAmber,
                        ),
                      )
                    : const Icon(Icons.file_download_outlined, size: 13),
                label: const Text(
                  '.CUBE',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 32,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _logProfiles.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, idx) {
              final prof = _logProfiles[idx];
              final selected = _edit.inputLogProfile == prof.id;
              return GestureDetector(
                onTap: () => _update(
                  _edit.copyWith(inputLogProfile: prof.id),
                  immediateUndo: true,
                ),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.cinemaAmber.withValues(alpha: 0.18)
                        : AppTheme.cardDark,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color:
                          selected ? AppTheme.cinemaAmber : AppTheme.hairline,
                    ),
                  ),
                  child: Text(
                    prof.label,
                    style: TextStyle(
                      color: selected ? AppTheme.cinemaAmber : Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        if (_savedPresets.isNotEmpty) ...[
          _sectionLabel('PRESET EDIT TERSIMPAN'),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _savedPresets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, idx) {
                final p = _savedPresets[idx];
                return InputChip(
                  label: Text(
                    p.name,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  deleteIconColor: Colors.white54,
                  onPressed: () => _applySavedPreset(p),
                  onDeleted: () async {
                    final next = await EditClipboardStore.deletePreset(p.id);
                    if (mounted) setState(() => _savedPresets = next);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 6),
        ],
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
            _captureUndoPoint(immediate: true);
            setState(() {
              _toneId = next.id;
              if (next.id == 'standard') _toneIntensity = 1.0;
              if (next.isLutTone) _stockEffects = false;
            });
            _scheduleRender(recordUndo: false);
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
            _captureUndoPoint();
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
                  _captureUndoPoint(immediate: true);
                  setState(() => _stockEffects = value);
                  _scheduleRender(recordUndo: false);
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

  // --------------------------------------------------------------- 6. EFFECTS
  Widget _buildEffectsTab() {
    return _scroll([
      EditSlider(
        label: 'Texture',
        value: _edit.texture,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(texture: value)),
      ),
      EditSlider(
        label: 'Clarity',
        value: _edit.clarity,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(clarity: value)),
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
      _sectionLabel('VIGNETTE LENGKAP'),
      EditSlider(
        label: 'Vignette Amount',
        value: _edit.vignette,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(vignette: value)),
      ),
      EditSlider(
        label: 'Midpoint',
        value: _edit.vignetteMidpoint,
        min: 0,
        max: 1,
        resetValue: 0.5,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(vignetteMidpoint: value)),
      ),
      EditSlider(
        label: 'Feather',
        value: _edit.vignetteFeather,
        min: 0,
        max: 1,
        resetValue: 0.5,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(vignetteFeather: value)),
      ),
      EditSlider(
        label: 'Roundness',
        value: _edit.vignetteRoundness,
        format: EditValueFormat.signed,
        onChanged: (value) => _update(_edit.copyWith(vignetteRoundness: value)),
      ),
      _sectionLabel('GRAIN LENGKAP'),
      EditSlider(
        label: 'Grain Amount',
        value: _edit.grain,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(grain: value)),
      ),
      EditSlider(
        label: 'Grain Size',
        value: _edit.grainSize,
        min: 0,
        max: 1,
        resetValue: 0.25,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(grainSize: value)),
      ),
      EditSlider(
        label: 'Roughness',
        value: _edit.grainRoughness,
        min: 0,
        max: 1,
        resetValue: 0.5,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(grainRoughness: value)),
      ),
    ]);
  }

  // ---------------------------------------------------------------- 7. DETAIL
  Widget _buildDetailTab() {
    return _scroll([
      _sectionLabel('SHARPENING'),
      EditSlider(
        label: 'Sharpen Amount',
        value: _edit.sharpen,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(sharpen: value)),
      ),
      EditSlider(
        label: 'Radius',
        value: _edit.sharpenRadius,
        min: 0,
        max: 1,
        resetValue: 0.35,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(sharpenRadius: value)),
      ),
      _sectionLabel('NOISE REDUCTION'),
      EditSlider(
        label: 'Color Noise Reduction (Tajam & Bersih)',
        value: _edit.colorNoiseReduction,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) =>
            _update(_edit.copyWith(colorNoiseReduction: value)),
      ),
      EditSlider(
        label: 'Luminance Noise Reduction',
        value: _edit.noiseReduction,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (value) => _update(_edit.copyWith(noiseReduction: value)),
      ),
    ]);
  }

  // ------------------------------------------------------------- 8. LENS BLUR
  Widget _buildLensBlurTab() {
    return _scroll([
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Row(
          children: [
            for (final style in const <({String id, String label})>[
              (id: 'radial', label: 'Radial Bokeh'),
              (id: 'linear', label: 'Tilt-Shift Linear'),
            ]) ...[
              ChoiceChip(
                label: Text(
                  style.label,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                selected: _edit.blurStyle == style.id,
                selectedColor: AppTheme.cinemaAmber,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                labelStyle: TextStyle(
                  color: _edit.blurStyle == style.id
                      ? Colors.black
                      : Colors.white70,
                ),
                onSelected: (_) => _update(
                  _edit.copyWith(blurStyle: style.id),
                  immediateUndo: true,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
        child: Text(
          'Ketuk / geser titik kuning di foto untuk pindah area fokus.',
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ),
      EditSlider(
        label: 'Blur Amount',
        value: _edit.blurAmount,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (v) => _update(_edit.copyWith(blurAmount: v)),
      ),
      EditSlider(
        label: 'Focus Area (Radius)',
        value: _edit.blurRadius,
        min: 0.05,
        max: 0.9,
        resetValue: 0.32,
        format: EditValueFormat.percent,
        onChanged: (v) => _update(_edit.copyWith(blurRadius: v)),
      ),
      EditSlider(
        label: 'Transition Feather',
        value: _edit.blurFeather,
        min: 0.05,
        max: 1.0,
        resetValue: 0.45,
        format: EditValueFormat.percent,
        onChanged: (v) => _update(_edit.copyWith(blurFeather: v)),
      ),
      EditSlider(
        label: 'Bokeh Highlight Boost',
        value: _edit.blurBokehBoost,
        min: 0,
        max: 1,
        resetValue: 0.25,
        format: EditValueFormat.percent,
        onChanged: (v) => _update(_edit.copyWith(blurBokehBoost: v)),
      ),
    ]);
  }

  // --------------------------------------------------------------- 9. MASKING
  Widget _buildMaskingTab() {
    final active = _selectedMask;

    void addMask(String type) {
      final index = _edit.masks.length + 1;
      final mask = SelectiveMask(
        id: 'mask_${DateTime.now().microsecondsSinceEpoch}',
        name: type == 'linear' ? 'Linear $index' : 'Radial $index',
        type: type,
        startX: 0.5,
        startY: type == 'linear' ? 0.12 : 0.5,
        endX: type == 'linear' ? 0.5 : 0.80,
        endY: type == 'linear' ? 0.52 : 0.5,
      );
      _update(
        _edit.copyWith(masks: <SelectiveMask>[..._edit.masks, mask]),
        immediateUndo: true,
      );
      setState(() => _selectedMaskId = mask.id);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.cinemaAmber,
                  side: const BorderSide(color: AppTheme.cinemaAmber),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => addMask('linear'),
                icon: const Icon(Icons.gradient_rounded, size: 14),
                label: const Text(
                  '+ LINEAR',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.cinemaAmber,
                  side: const BorderSide(color: AppTheme.cinemaAmber),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => addMask('radial'),
                icon: const Icon(Icons.radio_button_checked_rounded, size: 14),
                label: const Text(
                  '+ RADIAL',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.cinemaAmber,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed:
                    _generatingMask ? null : () => _generateAiMask('subject'),
                icon: _generatingMask
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: Colors.black,
                        ),
                      )
                    : const Icon(Icons.person_search_rounded, size: 14),
                label: Text(
                  AppStrings.of(context).subjectAi,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.cinemaAmber,
                  side: const BorderSide(color: AppTheme.cinemaAmber),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed:
                    _generatingMask ? null : () => _generateAiMask('sky'),
                icon: const Icon(Icons.wb_cloudy_outlined, size: 14),
                label: Text(
                  AppStrings.of(context).skyBgAi,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_edit.masks.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
            child: Text(
              'Tambah Gradien Linear (misal gelapkan langit) atau Gradien Radial '
              '(misal sorot subjek), lalu geser titik kontrol langsung di atas foto.',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          )
        else ...[
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              itemCount: _edit.masks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, idx) {
                final m = _edit.masks[idx];
                final selected = m.id == active?.id;
                return InputChip(
                  label: Text(
                    m.name,
                    style: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  selected: selected,
                  selectedColor: AppTheme.cinemaAmber,
                  backgroundColor: Colors.white.withValues(alpha: 0.08),
                  deleteIconColor: selected ? Colors.black87 : Colors.white54,
                  onSelected: (_) => setState(() => _selectedMaskId = m.id),
                  onDeleted: () {
                    final next =
                        _edit.masks.where((e) => e.id != m.id).toList();
                    _update(_edit.copyWith(masks: next), immediateUndo: true);
                    setState(_ensureValidSelectedMask);
                  },
                );
              },
            ),
          ),
          if (active != null) ...[
            SwitchListTile(
              dense: true,
              value: active.inverted,
              activeThumbColor: AppTheme.cinemaAmber,
              title: const Text(
                'Invert Mask (Balik Area)',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              ),
              onChanged: (v) => _update(
                _edit.withMaskUpdated(active.copyWith(inverted: v)),
                immediateUndo: true,
              ),
            ),
            EditSlider(
              label: 'Feather (Kehalusan)',
              value: active.feather,
              min: 0.05,
              max: 1.0,
              resetValue: 0.5,
              format: EditValueFormat.percent,
              onChanged: (v) =>
                  _update(_edit.withMaskUpdated(active.copyWith(feather: v))),
            ),
            EditSlider(
              label: 'Exposure Lokal',
              value: active.exposure,
              min: -2,
              max: 2,
              format: EditValueFormat.exposure,
              onChanged: (v) =>
                  _update(_edit.withMaskUpdated(active.copyWith(exposure: v))),
            ),
            EditSlider(
              label: 'Contrast Lokal',
              value: active.contrast,
              format: EditValueFormat.signed,
              onChanged: (v) =>
                  _update(_edit.withMaskUpdated(active.copyWith(contrast: v))),
            ),
            EditSlider(
              label: 'Highlights Lokal',
              value: active.highlights,
              format: EditValueFormat.signed,
              onChanged: (v) => _update(
                _edit.withMaskUpdated(active.copyWith(highlights: v)),
              ),
            ),
            EditSlider(
              label: 'Shadows Lokal',
              value: active.shadows,
              format: EditValueFormat.signed,
              onChanged: (v) =>
                  _update(_edit.withMaskUpdated(active.copyWith(shadows: v))),
            ),
            EditSlider(
              label: 'Suhu Lokal',
              value: active.temperature,
              format: EditValueFormat.signed,
              onChanged: (v) => _update(
                _edit.withMaskUpdated(active.copyWith(temperature: v)),
              ),
            ),
            EditSlider(
              label: 'Saturation Lokal',
              value: active.saturation,
              format: EditValueFormat.signed,
              onChanged: (v) => _update(
                _edit.withMaskUpdated(active.copyWith(saturation: v)),
              ),
            ),
            EditSlider(
              label: 'Clarity Lokal',
              value: active.clarity,
              format: EditValueFormat.signed,
              onChanged: (v) =>
                  _update(_edit.withMaskUpdated(active.copyWith(clarity: v))),
            ),
            EditSlider(
              label: 'Sharpen Lokal',
              value: active.sharpen,
              min: 0,
              max: 1,
              format: EditValueFormat.percent,
              onChanged: (v) =>
                  _update(_edit.withMaskUpdated(active.copyWith(sharpen: v))),
            ),
          ],
        ],
      ],
    );
  }

  // --------------------------------------------------------- 10. OPTICS & CROP
  Widget _buildOpticsCropTab() {
    final s = AppStrings.of(context);
    return _scroll([
      if (_isVideo) ...[
        _sectionLabel(s.videoTrim),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                '${(_edit.trimStart * 100).round()}%',
                style: AppTheme.monoStyle(
                  color: AppTheme.cinemaAmber,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Expanded(
                child: RangeSlider(
                  values: RangeValues(_edit.trimStart, _edit.trimEnd),
                  min: 0.0,
                  max: 1.0,
                  activeColor: AppTheme.cinemaAmber,
                  inactiveColor: Colors.white12,
                  onChanged: (range) => _update(
                    _edit.copyWith(trimStart: range.start, trimEnd: range.end),
                  ),
                ),
              ),
              Text(
                '${(_edit.trimEnd * 100).round()}%',
                style: AppTheme.monoStyle(
                  color: AppTheme.cinemaAmber,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        SwitchListTile(
          dense: true,
          value: _edit.normalizeAudio,
          activeThumbColor: AppTheme.cinemaAmber,
          title: Text(
            s.normalizeAudio,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
          ),
          onChanged: (v) => _update(
            _edit.copyWith(normalizeAudio: v),
            immediateUndo: true,
          ),
        ),
      ],
      _sectionLabel(s.frameFormat),
      SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _cropAspects.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, idx) {
            final ratio = _cropAspects[idx];
            final selected = _edit.cropAspect == ratio;
            return ChoiceChip(
              label: Text(
                ratio == 'original' ? 'Asli' : ratio,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              selected: selected,
              selectedColor: AppTheme.cinemaAmber,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              labelStyle: TextStyle(
                color: selected ? Colors.black : Colors.white70,
              ),
              onSelected: (_) => _update(
                _edit.copyWith(cropAspect: ratio),
                immediateUndo: true,
              ),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(
          children: [
            _transformButton(
              icon: Icons.rotate_90_degrees_cw_rounded,
              label: 'Putar 90°',
              active: _edit.rotateQuarterTurns != 0,
              onTap: () => _update(
                _edit.copyWith(
                  rotateQuarterTurns: (_edit.rotateQuarterTurns + 1) % 4,
                ),
                immediateUndo: true,
              ),
            ),
            const SizedBox(width: 8),
            _transformButton(
              icon: Icons.flip_rounded,
              label: 'Flip H',
              active: _edit.flipHorizontal,
              onTap: () => _update(
                _edit.copyWith(flipHorizontal: !_edit.flipHorizontal),
                immediateUndo: true,
              ),
            ),
            const SizedBox(width: 8),
            _transformButton(
              icon: Icons.flip_rounded,
              label: 'Flip V',
              active: _edit.flipVertical,
              onTap: () => _update(
                _edit.copyWith(flipVertical: !_edit.flipVertical),
                immediateUndo: true,
              ),
            ),
          ],
        ),
      ),
      EditSlider(
        label: 'Straighten (Luruskan Horizon)',
        value: _edit.straightenDegrees,
        min: -45,
        max: 45,
        format: EditValueFormat.straighten,
        onChanged: (v) => _update(_edit.copyWith(straightenDegrees: v)),
      ),
      _sectionLabel('GEOMETRI PERSPEKTIF'),
      EditSlider(
        label: 'Vertical Perspective',
        value: _edit.verticalPerspective,
        format: EditValueFormat.signed,
        onChanged: (v) => _update(_edit.copyWith(verticalPerspective: v)),
      ),
      EditSlider(
        label: 'Horizontal Perspective',
        value: _edit.horizontalPerspective,
        format: EditValueFormat.signed,
        onChanged: (v) => _update(_edit.copyWith(horizontalPerspective: v)),
      ),
      _sectionLabel('OPTIK LENSA'),
      EditSlider(
        label: 'Lens Distortion',
        value: _edit.lensDistortion,
        format: EditValueFormat.signed,
        onChanged: (v) => _update(_edit.copyWith(lensDistortion: v)),
      ),
      EditSlider(
        label: 'Hapus Vignette Lensa',
        value: _edit.opticsVignette,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (v) => _update(_edit.copyWith(opticsVignette: v)),
      ),
      EditSlider(
        label: 'Defringe (Chromatic Aberration)',
        value: _edit.defringe,
        min: 0,
        max: 1,
        format: EditValueFormat.percent,
        onChanged: (v) => _update(_edit.copyWith(defringe: v)),
      ),
    ]);
  }

  Widget _transformButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.cinemaAmber.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? AppTheme.cinemaAmber
                  : Colors.white.withValues(alpha: 0.1),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? AppTheme.cinemaAmber : Colors.white70,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: active ? AppTheme.cinemaAmber : Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExportOverlay() {
    final s = AppStrings.of(context);
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
                _isVideo ? s.renderingVideo : s.renderingPhoto,
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

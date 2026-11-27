// lib/features/cinema_camera/presentation/screens/captured_gallery_screen.dart

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../photo_editor/data/edit_clipboard_store.dart';
import '../../../photo_editor/data/photo_editor_repository.dart';
import '../../../photo_editor/domain/entities/photo_edit.dart';
import '../../domain/entities/captured_media.dart';
import '../../domain/entities/cinema_tone.dart';
import '../../domain/entities/film_look.dart';
import '../providers/cinema_camera_provider.dart';

enum _GalleryFilter { all, photo, video, imported }

/// Editorial Pro Gallery with Filter Pills and Multi-Select Batch Delete / Save.
class CapturedGalleryScreen extends ConsumerStatefulWidget {
  const CapturedGalleryScreen({super.key});

  @override
  ConsumerState<CapturedGalleryScreen> createState() =>
      _CapturedGalleryScreenState();
}

class _CapturedGalleryScreenState extends ConsumerState<CapturedGalleryScreen> {
  List<CapturedMedia> _items = const <CapturedMedia>[];
  bool _loading = true;
  bool _importing = false;
  bool _batchBusy = false;
  String? _batchProgressText;

  _GalleryFilter _filter = _GalleryFilter.all;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  // Apple Photos-style slide-to-multi-select gesture state
  final ScrollController _gridScrollController = ScrollController();
  Timer? _autoScrollTimer;
  int? _dragStartIndex;
  int? _dragLastIndex;
  bool _dragSelectMode = true;
  Set<String> _dragInitialSelection = const <String>{};
  double _dragLocalX = 0;
  double _dragLocalY = 0;
  double _gridViewportW = 0;
  double _gridViewportH = 0;
  int _gridCols = 3;
  List<CapturedMedia> _gridVisibleItems = const <CapturedMedia>[];

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _gridScrollController.dispose();
    super.dispose();
  }

  int? _hitTestGridIndex(Offset localPos) {
    final count = _gridVisibleItems.length;
    if (count == 0 || _gridViewportW <= 0 || _gridCols <= 0) return null;
    const hPad = 3.0;
    const topPad = 6.0;
    const spacing = 3.0;
    const aspectRatio = 0.75;
    final tileW =
        (_gridViewportW - hPad * 2 - spacing * (_gridCols - 1)) / _gridCols;
    if (tileW <= 1) return null;
    final tileH = tileW / aspectRatio;
    final scrollOffset =
        _gridScrollController.hasClients ? _gridScrollController.offset : 0.0;
    final contentX = (localPos.dx - hPad).clamp(0.0, _gridViewportW - hPad * 2);
    final contentY = localPos.dy + scrollOffset - topPad;
    if (contentY < 0) return 0;
    final col = (contentX / (tileW + spacing)).floor().clamp(0, _gridCols - 1);
    final row = (contentY / (tileH + spacing)).floor();
    final idx = row * _gridCols + col;
    if (idx < 0) return 0;
    if (idx >= count) return count - 1;
    return idx;
  }

  void _onSlideSelectStart(DragStartDetails details) {
    if (!_selectionMode || _batchBusy) return;
    _dragLocalX = details.localPosition.dx;
    _dragLocalY = details.localPosition.dy;
    final startIdx = _hitTestGridIndex(details.localPosition);
    if (startIdx == null) return;
    final startItem = _gridVisibleItems[startIdx];
    _dragStartIndex = startIdx;
    _dragLastIndex = startIdx;
    _dragSelectMode = !_selectedIds.contains(startItem.id);
    _dragInitialSelection = Set<String>.from(_selectedIds);
    HapticFeedback.selectionClick();
    setState(() {
      if (_dragSelectMode) {
        _selectedIds.add(startItem.id);
      } else {
        _selectedIds.remove(startItem.id);
      }
    });
  }

  void _onSlideSelectUpdate(DragUpdateDetails details) {
    if (!_selectionMode || _dragStartIndex == null) return;
    _dragLocalX = details.localPosition.dx;
    _dragLocalY = details.localPosition.dy;
    _applySlideSelectionAt(details.localPosition);
    _updateAutoScroll(details.localPosition.dy);
  }

  void _applySlideSelectionAt(Offset localPos) {
    final startIndex = _dragStartIndex;
    if (startIndex == null) return;
    final currentIdx = _hitTestGridIndex(localPos);
    if (currentIdx == null || currentIdx == _dragLastIndex) return;
    _dragLastIndex = currentIdx;

    final lo = math.min(startIndex, currentIdx);
    final hi = math.max(startIndex, currentIdx);
    final next = Set<String>.from(_dragInitialSelection);
    for (var i = lo; i <= hi && i < _gridVisibleItems.length; i++) {
      final id = _gridVisibleItems[i].id;
      if (_dragSelectMode) {
        next.add(id);
      } else {
        next.remove(id);
      }
    }
    HapticFeedback.selectionClick();
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(next);
    });
  }

  void _updateAutoScroll(double localY) {
    const edgeZone = 68.0;
    final nearTop = localY < edgeZone;
    final nearBottom = _gridViewportH > 0 && localY > _gridViewportH - edgeZone;
    if (!nearTop && !nearBottom) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      return;
    }
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted ||
          _dragStartIndex == null ||
          !_gridScrollController.hasClients) {
        _autoScrollTimer?.cancel();
        _autoScrollTimer = null;
        return;
      }
      final pos = _gridScrollController.position;
      double delta = 0;
      if (_dragLocalY < edgeZone) {
        final factor = ((edgeZone - _dragLocalY) / edgeZone).clamp(0.1, 1.0);
        delta = -10.0 * factor;
      } else if (_gridViewportH > 0 && _dragLocalY > _gridViewportH - edgeZone) {
        final factor =
            ((_dragLocalY - (_gridViewportH - edgeZone)) / edgeZone)
                .clamp(0.1, 1.0);
        delta = 10.0 * factor;
      }
      if (delta == 0) return;
      final target = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
      if ((target - pos.pixels).abs() < 0.2) return;
      _gridScrollController.jumpTo(target);
      _applySlideSelectionAt(Offset(_dragLocalX, _dragLocalY));
    });
  }

  void _onSlideSelectEnd() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragStartIndex = null;
    _dragLastIndex = null;
    _dragInitialSelection = const <String>{};
  }

  Future<void> _loadMedia() async {
    setState(() => _loading = true);
    final items =
        await ref.read(cinemaCameraProvider.notifier).loadCapturedMedia();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
      final existingIds = items.map((e) => e.id).toSet();
      _selectedIds.removeWhere((id) => !existingIds.contains(id));
      if (_selectedIds.isEmpty && _items.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  List<CapturedMedia> get _filteredItems {
    return switch (_filter) {
      _GalleryFilter.all => _items,
      _GalleryFilter.photo => _items.where((m) => !m.isVideo).toList(),
      _GalleryFilter.video => _items.where((m) => m.isVideo).toList(),
      _GalleryFilter.imported => _items.where((m) => m.isImported).toList(),
    };
  }

  List<CapturedMedia> get _selectedItems =>
      _items.where((m) => _selectedIds.contains(m.id)).toList();

  void _toggleSelectionMode() {
    HapticFeedback.selectionClick();
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedIds.clear();
    });
  }

  void _toggleItemSelection(CapturedMedia media) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(media.id)) {
        _selectedIds.remove(media.id);
      } else {
        _selectedIds.add(media.id);
      }
    });
  }

  void _toggleSelectAll(List<CapturedMedia> visible) {
    HapticFeedback.selectionClick();
    setState(() {
      final allVisibleSelected = visible.isNotEmpty &&
          visible.every((m) => _selectedIds.contains(m.id));
      if (allVisibleSelected) {
        for (final m in visible) {
          _selectedIds.remove(m.id);
        }
      } else {
        for (final m in visible) {
          _selectedIds.add(m.id);
        }
      }
    });
  }

  CinemaTone _resolveTone(CapturedMedia media) {
    final tones = ref.read(cinemaCameraProvider).valueOrNull?.tones ??
        const <CinemaTone>[];
    for (final tone in tones) {
      if (tone.id == media.toneId) return tone;
    }
    return CinemaTone(
      id: media.toneId,
      name: media.toneName,
      filmReference: 'CineLens',
      description: '',
      accentColorHex: 0xFFE5A93B,
      matrix: CinemaTone.identityMatrix,
    );
  }

  Future<void> _openMedia(CapturedMedia media) async {
    if (_selectionMode) {
      _toggleItemSelection(media);
      return;
    }
    final tone = _resolveTone(media);
    final result = media.isVideo
        ? await context.push<bool>(
            '/preview',
            extra: CapturedPreviewArgs.video(
              videoFilePath: media.path,
              tone: tone,
              intensity: media.intensity,
              isAnamorphic: media.isAnamorphic,
            ),
          )
        : await context.push<bool>(
            '/preview',
            extra: CapturedPreviewArgs.photoFile(
              imageFilePath: media.path,
              tone: tone,
              intensity: media.intensity,
              isAnamorphic: media.isAnamorphic,
            ),
          );
    if (result == true && mounted) await _loadMedia();
  }

  Future<void> _importFromPhotos() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final imported = await ref
          .read(cinemaCameraProvider.notifier)
          .importFromPhotoLibrary();
      if (!mounted) return;
      setState(() => _importing = false);
      if (imported.isEmpty) return;
      await _loadMedia();
      if (mounted) {
        _snack('+${imported.length} ${AppStrings.of(context).importedMedia}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _importing = false);
      _snack(_describe(error));
    }
  }

  Future<void> _batchSaveToPhotos() async {
    final selected = _selectedItems;
    if (selected.isEmpty || _batchBusy) return;
    setState(() => _batchBusy = true);
    var saved = 0;
    final notifier = ref.read(cinemaCameraProvider.notifier);
    for (final item in selected) {
      try {
        await notifier.saveMediaToPhotos(item);
        saved++;
      } catch (_) {}
    }
    if (!mounted) return;
    final s = AppStrings.of(context);
    setState(() {
      _batchBusy = false;
      _selectionMode = false;
      _selectedIds.clear();
    });
    _snack(s.savedToPhotosCount(saved));
  }

  Future<void> _confirmBatchDelete() async {
    final selected = _selectedItems;
    if (selected.isEmpty || _batchBusy) return;
    final s = AppStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: Text(
          s.deleteItemsTitle(selected.length),
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
        ),
        content: Text(
          s.deleteItemsBody(selected.length),
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
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
    if (confirmed != true || !mounted) return;

    setState(() => _batchBusy = true);
    await ref
        .read(cinemaCameraProvider.notifier)
        .deleteCapturedMediaBatch(selected);
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _selectionMode = false;
      _selectedIds.clear();
    });
    await _loadMedia();
    if (mounted) _snack(s.deletedCount(selected.length));
  }

  Future<void> _openBatchEditSheet() async {
    final selected = _selectedItems;
    if (selected.isEmpty || _batchBusy) return;
    final s = AppStrings.of(context);
    final presets = await EditClipboardStore.loadPresets();
    final tones = ref.read(cinemaCameraProvider).valueOrNull?.tones ??
        const <CinemaTone>[];
    final clipboard = EditClipboardStore.clipboard;
    if (!mounted) return;

    final chosen = await showModalBottomSheet<
        ({
          String label,
          PhotoEdit edit,
          String toneId,
          double toneIntensity,
          bool stockEffects,
          FilmLook? film,
        })>(
      context: context,
      backgroundColor: AppTheme.surfaceDark,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.65,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${s.batchEdit.toUpperCase()} (${selected.length})',
                  style: const TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (clipboard != null)
                        _batchChoiceTile(
                          icon: Icons.content_paste_rounded,
                          title: s.applyClipboard,
                          subtitle: clipboard.toneId.toUpperCase(),
                          accent: true,
                          onTap: () => Navigator.of(sheetCtx).pop((
                            label: s.applyClipboard,
                            edit: clipboard.edit,
                            toneId: clipboard.toneId,
                            toneIntensity: clipboard.toneIntensity,
                            stockEffects: clipboard.stockEffects,
                            film: clipboard.film,
                          )),
                        ),
                      for (final preset in presets)
                        _batchChoiceTile(
                          icon: Icons.auto_awesome_rounded,
                          title: preset.name,
                          subtitle: preset.toneId.toUpperCase(),
                          onTap: () => Navigator.of(sheetCtx).pop((
                            label: preset.name,
                            edit: preset.edit,
                            toneId: preset.toneId,
                            toneIntensity: preset.toneIntensity,
                            stockEffects: preset.stockEffects,
                            film: null,
                          )),
                        ),
                      for (final tone in tones)
                        _batchChoiceTile(
                          icon: Icons.movie_filter_outlined,
                          title: tone.name,
                          subtitle: tone.filmReference,
                          onTap: () => Navigator.of(sheetCtx).pop((
                            label: tone.name,
                            edit: PhotoEdit.neutral,
                            toneId: tone.id,
                            toneIntensity: 1.0,
                            stockEffects: true,
                            film: null,
                          )),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (chosen == null || !mounted) return;
    await _runBatchEdit(
      items: selected,
      edit: chosen.edit,
      toneId: chosen.toneId,
      toneIntensity: chosen.toneIntensity,
      stockEffects: chosen.stockEffects,
      film: chosen.film,
    );
  }

  Widget _batchChoiceTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool accent = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: accent
                ? AppTheme.cinemaAmber.withValues(alpha: 0.14)
                : AppTheme.cardDark,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: accent ? AppTheme.cinemaAmber : AppTheme.hairline,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: accent ? AppTheme.cinemaAmber : AppTheme.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accent
                            ? AppTheme.cinemaAmber
                            : AppTheme.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 10.5,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppTheme.textSecondary,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runBatchEdit({
    required List<CapturedMedia> items,
    required PhotoEdit edit,
    required String toneId,
    required double toneIntensity,
    required bool stockEffects,
    required FilmLook? film,
  }) async {
    final s = AppStrings.of(context);
    final tones = ref.read(cinemaCameraProvider).valueOrNull?.tones ??
        const <CinemaTone>[];
    CinemaTone? matchedTone;
    for (final t in tones) {
      if (t.id == toneId) {
        matchedTone = t;
        break;
      }
    }

    final payload = <String, dynamic>{
      'edit': edit.toParameters(),
      'toneId': (matchedTone != null &&
              (matchedTone.isLutTone || matchedTone.isCustom))
          ? null
          : (toneId == 'standard' ? null : toneId),
      'intensity': toneIntensity,
      if (matchedTone != null && !matchedTone.isLutTone && matchedTone.isCustom)
        'matrix': matchedTone.blendedMatrix(toneIntensity),
    };
    if (matchedTone != null && matchedTone.isLutTone) {
      payload['look'] = (film ?? const FilmLook())
          .copyWith(useStockEffects: false)
          .toNative(
            lutPath: matchedTone.lutPath,
            lutSize: matchedTone.lutSize,
            mix: toneIntensity,
          );
    } else if (!stockEffects && film != null) {
      payload['look'] = film.copyWith(useStockEffects: false).toNative();
    }

    final editorRepo = ref.read(photoEditorRepositoryProvider);
    final camRepo = ref.read(cinemaCameraRepositoryProvider);
    final toneLabel = matchedTone?.name ?? 'Edited';
    var doneCount = 0;

    setState(() {
      _batchBusy = true;
      _batchProgressText = s.batchRendering(0, items.length);
    });

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (mounted) {
        setState(() {
          _batchProgressText = s.batchRendering(i + 1, items.length);
        });
      }
      try {
        if (item.isVideo) {
          final exportedPath = await editorRepo.exportVideo(
            path: item.path,
            payload: payload,
          );
          await camRepo.storeVideo(
            sourcePath: exportedPath,
            toneId: toneId,
            toneName: toneLabel,
            intensity: toneIntensity,
            isAnamorphic: item.isAnamorphic,
          );
        } else {
          final bytes = await editorRepo.exportPhoto(
            path: item.path,
            payload: payload,
          );
          await camRepo.storePhoto(
            jpegBytes: bytes,
            toneId: toneId,
            toneName: toneLabel,
            intensity: toneIntensity,
            isAnamorphic: item.isAnamorphic,
          );
        }
        doneCount++;
      } catch (_) {
        // Continue remaining items if one fails.
      }
    }

    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _batchProgressText = null;
      _selectionMode = false;
      _selectedIds.clear();
    });
    await _loadMedia();
    if (mounted) _snack(s.batchDone(doneCount));
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontSize: 12)),
          backgroundColor: AppTheme.cardDark,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  String _describe(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final visible = _filteredItems;

    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundBlack,
        title: Text(
          _selectionMode && _selectedIds.isNotEmpty
              ? s.selectedCount(_selectedIds.length).toUpperCase()
              : s.gallery,
        ),
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              onPressed: _batchBusy ? null : _toggleSelectionMode,
              child: Text(
                _selectionMode ? s.done : s.select,
                style: TextStyle(
                  color: _selectionMode
                      ? AppTheme.cinemaAmber
                      : AppTheme.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (!_selectionMode)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: _importing
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.cinemaAmber,
                        ),
                      ),
                    )
                  : GestureDetector(
                      onTap: _importFromPhotos,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 11),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.cinemaAmber,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          '+ ${s.importLabel}',
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
      body: SafeArea(
        child: Column(
          children: [
            _buildFilterBar(s),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              child: _selectionMode
                  ? Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.cinemaAmber.withValues(alpha: 0.10),
                        border: const Border(
                          bottom:
                              BorderSide(color: AppTheme.hairline, width: 0.7),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.swipe_rounded,
                            size: 13,
                            color: AppTheme.cinemaAmber,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            s.isId
                                ? 'Geser menyamping pada foto/video untuk pilih banyak sekaligus'
                                : 'Slide sideways across items to multi-select',
                            style: const TextStyle(
                              color: AppTheme.cinemaAmber,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CupertinoActivityIndicator(
                        color: AppTheme.cinemaAmber,
                      ),
                    )
                  : visible.isEmpty
                      ? _buildEmptyState(s)
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final cols =
                                (constraints.maxWidth / 124).floor().clamp(3, 6);
                            _gridViewportW = constraints.maxWidth;
                            _gridViewportH = constraints.maxHeight;
                            _gridCols = cols;
                            _gridVisibleItems = visible;

                            final grid = GridView.builder(
                              controller: _gridScrollController,
                              physics: const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              ),
                              padding: const EdgeInsets.fromLTRB(3, 6, 3, 16),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cols,
                                mainAxisSpacing: 3,
                                crossAxisSpacing: 3,
                                childAspectRatio: 0.75,
                              ),
                              itemCount: visible.length,
                              itemBuilder: (context, i) =>
                                  _buildTile(visible[i], s),
                            );

                            if (!_selectionMode) return grid;

                            return GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onHorizontalDragStart: _onSlideSelectStart,
                              onHorizontalDragUpdate: _onSlideSelectUpdate,
                              onHorizontalDragEnd: (_) => _onSlideSelectEnd(),
                              onHorizontalDragCancel: _onSlideSelectEnd,
                              child: grid,
                            );
                          },
                        ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => SizeTransition(
                sizeFactor: anim,
                axisAlignment: -1.0,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: _selectionMode
                  ? _buildBatchActionBar(s, visible)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar(AppStrings s) {
    final filters = [
      (_GalleryFilter.all, s.allMedia),
      (_GalleryFilter.photo, s.photo),
      (_GalleryFilter.video, s.video),
      (_GalleryFilter.imported, s.importedMedia),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.hairline, width: 0.7)),
      ),
      child: Row(
        children: [
          for (final (filter, label) in filters) ...[
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _filter = filter);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _filter == filter
                      ? AppTheme.cinemaAmber.withValues(alpha: 0.16)
                      : AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _filter == filter
                        ? AppTheme.cinemaAmber
                        : AppTheme.hairline,
                    width: 0.9,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: _filter == filter
                        ? AppTheme.cinemaAmber
                        : AppTheme.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildBatchActionBar(AppStrings s, List<CapturedMedia> visible) {
    final count = _selectedIds.length;
    final allSelected =
        visible.isNotEmpty && visible.every((m) => _selectedIds.contains(m.id));

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceDark,
        border: Border(top: BorderSide(color: AppTheme.hairline, width: 0.8)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _batchBusy ? null : () => _toggleSelectAll(visible),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: allSelected
                    ? AppTheme.cinemaAmber.withValues(alpha: 0.16)
                    : AppTheme.cardDark,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: allSelected ? AppTheme.cinemaAmber : AppTheme.hairline,
                ),
              ),
              child: Text(
                s.selectAll,
                style: TextStyle(
                  color: allSelected
                      ? AppTheme.cinemaAmber
                      : AppTheme.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const Spacer(),
          if (_batchBusy)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.cinemaAmber,
                  ),
                ),
                if (_batchProgressText != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    _batchProgressText!,
                    style: AppTheme.monoStyle(
                      color: AppTheme.cinemaAmber,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            )
          else ...[
            OutlinedButton.icon(
              onPressed: count == 0 ? null : _openBatchEditSheet,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.cinemaAmber,
                side: BorderSide(
                  color: count == 0
                      ? AppTheme.hairline
                      : AppTheme.cinemaAmber.withValues(alpha: 0.7),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              icon: const Icon(Icons.auto_fix_high_rounded, size: 14),
              label: Text(
                s.batchEdit,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: count == 0 ? null : _batchSaveToPhotos,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textPrimary,
                side: const BorderSide(color: AppTheme.hairline),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              icon: const Icon(Icons.ios_share_rounded, size: 14),
              label: Text(
                s.save,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: count == 0 ? null : _confirmBatchDelete,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.cinemaRed,
                disabledBackgroundColor:
                    AppTheme.cinemaRed.withValues(alpha: 0.25),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 15),
              label: Text(
                count > 0 ? '${s.delete} ($count)' : s.delete,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(AppStrings s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              color: Colors.white24,
              size: 46,
            ),
            const SizedBox(height: 12),
            Text(
              s.emptyGalleryTitle,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              s.emptyGallerySub,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _importFromPhotos,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.cinemaAmber,
                foregroundColor: Colors.black,
              ),
              child: Text(
                '+ ${s.importLabel}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(CapturedMedia media, AppStrings s) {
    final isSelected = _selectedIds.contains(media.id);

    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => _openMedia(media),
        onLongPress: () {
          HapticFeedback.mediumImpact();
          setState(() {
            _selectionMode = true;
            _selectedIds.add(media.id);
          });
        },
        child: AnimatedScale(
          scale: isSelected ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: AppTheme.cardDark,
              borderRadius: BorderRadius.circular(isSelected ? 7 : 4),
              border: Border.all(
                color: isSelected ? AppTheme.cinemaAmber : Colors.transparent,
                width: isSelected ? 2.0 : 0.0,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (media.isVideo)
                  _VideoPosterTile(path: media.path)
                else
                  Hero(
                    tag: 'media_${media.path}',
                    child: Image.file(
                      File(media.path),
                      fit: BoxFit.cover,
                      cacheWidth: 340,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Color(0xFF141418),
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white24,
                          size: 24,
                        ),
                      ),
                    ),
                  ),

            if (isSelected)
              ColoredBox(color: AppTheme.cinemaAmber.withValues(alpha: 0.16)),

            // Bottom editorial caption scrim
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 14, 6, 5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.78),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        media.toneName.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),
                    if (media.isVideo)
                      const Icon(
                        Icons.videocam_rounded,
                        color: AppTheme.cinemaAmber,
                        size: 11,
                      ),
                  ],
                ),
              ),
            ),

            // Top-right Selection Checkbox OR Media Type Badge
            if (_selectionMode)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected
                        ? AppTheme.cinemaAmber
                        : Colors.black.withValues(alpha: 0.55),
                    border: Border.all(
                      color: isSelected ? AppTheme.cinemaAmber : Colors.white70,
                      width: 1.5,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(
                          Icons.check_rounded,
                          color: Colors.black,
                          size: 14,
                        )
                      : null,
                ),
              )
            else if (media.isImported || media.isVideo)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    media.isImported ? s.importedMedia : s.video,
                    style: AppTheme.monoStyle(
                      color: Colors.white,
                      fontSize: 7.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}

/// Fetches & caches a native video poster thumbnail + duration pill so videos
/// in the gallery show real first-frame previews instead of grey boxes.
class _VideoPosterTile extends ConsumerStatefulWidget {
  final String path;
  const _VideoPosterTile({required this.path});

  @override
  ConsumerState<_VideoPosterTile> createState() => _VideoPosterTileState();
}

class _VideoPosterTileState extends ConsumerState<_VideoPosterTile> {
  String? _thumbPath;
  double _durationSeconds = 0;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  @override
  void didUpdateWidget(covariant _VideoPosterTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _thumbPath = null;
      _durationSeconds = 0;
      _loadThumb();
    }
  }

  Future<void> _loadThumb() async {
    final res = await ref
        .read(cinemaCameraRepositoryProvider)
        .generateVideoThumbnail(widget.path);
    if (!mounted || res.isEmpty) return;
    final thumb = res['thumbPath'] as String?;
    final dur = (res['durationSeconds'] as num?)?.toDouble() ?? 0.0;
    setState(() {
      _thumbPath = thumb;
      _durationSeconds = dur;
    });
  }

  String _fmtDuration(double sec) {
    final total = sec.round().clamp(0, 35999);
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final path = _thumbPath;
    final hasFile = path != null && path.isNotEmpty && File(path).existsSync();

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hasFile)
          Image.file(
            File(path),
            fit: BoxFit.cover,
            cacheWidth: 340,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Color(0xFF141418)),
          )
        else
          const ColoredBox(color: Color(0xFF141418)),
        Center(
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.48),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
        if (_durationSeconds > 0.2)
          Positioned(
            top: 5,
            left: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _fmtDuration(_durationSeconds),
                style: AppTheme.monoStyle(
                  color: Colors.white,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

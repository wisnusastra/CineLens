// lib/features/cinema_camera/presentation/screens/captured_gallery_screen.dart

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/captured_media.dart';
import '../../domain/entities/cinema_tone.dart';
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

  _GalleryFilter _filter = _GalleryFilter.all;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadMedia();
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
                            return GridView.builder(
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
                          },
                        ),
            ),
            if (_selectionMode) _buildBatchActionBar(s, visible),
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
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.cinemaAmber,
              ),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: count == 0 ? null : _batchSaveToPhotos,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textPrimary,
                side: const BorderSide(color: AppTheme.hairline),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              icon: const Icon(Icons.ios_share_rounded, size: 15),
              label: Text(
                s.save,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: count == 0 ? null : _confirmBatchDelete,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.cinemaRed,
                disabledBackgroundColor:
                    AppTheme.cinemaRed.withValues(alpha: 0.25),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: Text(
                count > 0 ? '${s.delete} ($count)' : s.delete,
                style: const TextStyle(
                  fontSize: 11,
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

    return GestureDetector(
      onTap: () => _openMedia(media),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        setState(() {
          _selectionMode = true;
          _selectedIds.add(media.id);
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: AppTheme.cardDark,
          borderRadius: BorderRadius.circular(4),
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
              const ColoredBox(
                color: Color(0xFF141418),
                child: Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white70,
                    size: 32,
                  ),
                ),
              )
            else
              Image.file(
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
    );
  }
}

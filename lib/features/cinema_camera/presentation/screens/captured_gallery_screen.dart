// lib/features/cinema_camera/presentation/screens/captured_gallery_screen.dart

import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/captured_media.dart';
import '../../domain/entities/cinema_tone.dart';
import '../providers/cinema_camera_provider.dart';

/// Local gallery of everything captured on this device plus everything imported
/// from the iPhone camera roll.
///
/// It reads the index kept by [CinemaCameraRepository] instead of Apple Photos,
/// so it opens instantly and works without library permission.
class CapturedGalleryScreen extends ConsumerStatefulWidget {
  const CapturedGalleryScreen({super.key});

  @override
  ConsumerState<CapturedGalleryScreen> createState() =>
      _CapturedGalleryScreenState();
}

class _CapturedGalleryScreenState extends ConsumerState<CapturedGalleryScreen> {
  late Future<List<CapturedMedia>> _mediaFuture;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _mediaFuture = ref.read(cinemaCameraProvider.notifier).loadCapturedMedia();
  }

  void _reload() {
    setState(() {
      _mediaFuture =
          ref.read(cinemaCameraProvider.notifier).loadCapturedMedia();
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
      filmReference: 'CineLens LUT',
      description: 'Preset tersimpan',
      accentColorHex: 0xFFFFC145,
      matrix: CinemaTone.identityMatrix,
    );
  }

  Future<void> _openMedia(CapturedMedia media) async {
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
    if (result == true && mounted) _reload();
  }

  Future<void> _openEditor(CapturedMedia media) async {
    final edited = await context.push<bool>(
      '/editor',
      extra: PhotoEditorArgs(
        path: media.path,
        isVideo: media.isVideo,
        bakedToneName: media.isImported ? '' : media.toneName,
      ),
    );
    if (edited == true && mounted) {
      _reload();
      _snack('Hasil edit ditambahkan ke galeri.');
    }
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
      if (imported.isEmpty) {
        _snack('Tidak ada foto atau video yang dipilih.');
        return;
      }
      _reload();
      _snack('${imported.length} media dari Photos ditambahkan ke galeri.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _importing = false);
      _snack('Gagal mengimpor: ${_describe(error)}');
    }
  }

  Future<void> _saveToPhotos(CapturedMedia media) async {
    try {
      await ref.read(cinemaCameraProvider.notifier).saveMediaToPhotos(media);
      if (!mounted) return;
      _snack('Disimpan ke Apple Photos.');
    } catch (error) {
      if (!mounted) return;
      _snack('Gagal menyimpan ke Photos: ${_describe(error)}');
    }
  }

  Future<void> _showActions(CapturedMedia media) async {
    final action = await showModalBottomSheet<String>(
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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(
                children: [
                  Icon(
                    media.isVideo
                        ? Icons.movie_outlined
                        : Icons.image_outlined,
                    color: AppTheme.cinemaAmber,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      media.toneName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.tune_rounded,
                color: AppTheme.cinemaAmber,
              ),
              title: const Text(
                'Edit (Cahaya, Warna, Kurva, Film)',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
              onTap: () => Navigator.of(sheetContext).pop('edit'),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: AppTheme.textPrimary,
              ),
              title: const Text(
                'Simpan ke Apple Photos',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
              onTap: () => Navigator.of(sheetContext).pop('photos'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.redAccent,
              ),
              title: const Text(
                'Hapus dari galeri',
                style: TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted) return;
    switch (action) {
      case 'edit':
        await _openEditor(media);
      case 'photos':
        await _saveToPhotos(media);
      case 'delete':
        await _confirmDelete(media);
    }
  }

  Future<void> _confirmDelete(CapturedMedia media) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title: const Text(
          'Hapus hasil?',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Text(
          media.isVideo
              ? 'Video ini akan dihapus dari galeri dan penyimpanan aplikasi.'
              : 'Foto ini akan dihapus dari galeri dan penyimpanan aplikasi.',
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

    await ref
        .read(cinemaCameraProvider.notifier)
        .deleteCapturedMedia(media);
    if (!mounted) return;
    _reload();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(fontSize: 12)),
          backgroundColor: AppTheme.surfaceDark,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
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
        title: const Text('GALERI CINELENS'),
        actions: [
          if (_importing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.cinemaAmber,
                  ),
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Impor dari Photos',
              icon: const Icon(Icons.add_photo_alternate_outlined),
              onPressed: _importFromPhotos,
            ),
          IconButton(
            tooltip: 'Muat ulang',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _reload,
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<CapturedMedia>>(
          future: _mediaFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CupertinoActivityIndicator(color: AppTheme.cinemaAmber),
              );
            }

            final media = snapshot.data ?? const <CapturedMedia>[];
            if (media.isEmpty) return _buildEmptyState();

            return LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    (constraints.maxWidth / 130).floor().clamp(2, 6);
                return GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    childAspectRatio: 0.74,
                  ),
                  itemCount: media.length,
                  itemBuilder: (context, index) => _buildTile(media[index]),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              color: Colors.white38,
              size: 54,
            ),
            const SizedBox(height: 14),
            const Text(
              'Belum ada hasil',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Foto dan video yang kamu ambil atau impor dari Photos akan muncul di sini.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _importFromPhotos,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                  label: const Text('Impor dari Photos'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => context.pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.cinemaAmber,
                  ),
                  child: const Text(
                    'Kamera',
                    style: TextStyle(color: Colors.black),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(CapturedMedia media) {
    return GestureDetector(
      onTap: () => _openMedia(media),
      onLongPress: () => _showActions(media),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: AppTheme.surfaceDark,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (media.isVideo)
                      _buildVideoTile(media)
                    else
                      Image.file(
                        File(media.path),
                        fit: BoxFit.cover,
                        cacheWidth: 360,
                        errorBuilder: (context, error, stackTrace) =>
                            const ColoredBox(
                          color: Color(0xFF151518),
                          child: Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white38,
                              size: 28,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          media.isImported
                              ? 'IMPOR'
                              : media.isVideo
                                  ? 'VIDEO'
                                  : 'FOTO',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      media.toneName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _formatTimestamp(media.createdAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 8,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Imported clips have no poster frame on disk yet, so the first frame is
  /// shown by the preview screen; the tile keeps the old play glyph.
  Widget _buildVideoTile(CapturedMedia media) {
    return const ColoredBox(
      color: Color(0xFF151518),
      child: Center(
        child: Icon(
          Icons.play_circle_fill_rounded,
          color: Colors.white70,
          size: 34,
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$day/$month ${value.year % 100} • $hour:$minute';
  }
}

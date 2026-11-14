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

/// Local gallery of everything captured on this device.
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

  void _openMedia(CapturedMedia media) {
    final tone = _resolveTone(media);
    if (media.isVideo) {
      context.push(
        '/preview',
        extra: CapturedPreviewArgs.video(
          videoFilePath: media.path,
          tone: tone,
          intensity: media.intensity,
          isAnamorphic: media.isAnamorphic,
        ),
      );
      return;
    }

    context.push(
      '/preview',
      extra: CapturedPreviewArgs.photoFile(
        imageFilePath: media.path,
        tone: tone,
        intensity: media.intensity,
        isAnamorphic: media.isAnamorphic,
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        title: const Text('GALERI CINELENS'),
        actions: [
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
              'Foto dan video yang kamu ambil akan muncul di sini.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 18),
            CupertinoButton.filled(
              onPressed: () => context.pop(),
              child: const Text('Kembali ke Kamera'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTile(CapturedMedia media) {
    return GestureDetector(
      onTap: () => _openMedia(media),
      onLongPress: () => _confirmDelete(media),
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
                      const ColoredBox(
                        color: Color(0xFF151518),
                        child: Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white70,
                            size: 34,
                          ),
                        ),
                      )
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
                          media.isVideo ? 'VIDEO' : 'FOTO',
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

  String _formatTimestamp(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$day/$month ${value.year % 100} • $hour:$minute';
  }
}

// lib/features/cinema_camera/presentation/widgets/media_specs_sheet.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/theme/app_theme.dart';
import '../providers/cinema_camera_provider.dart';

/// Displays technical EXIF / Video codec specs fetched natively from iOS
/// (`CGImageSource` / `AVAsset`).
Future<void> showMediaSpecsSheet(
  BuildContext context,
  WidgetRef ref, {
  required String path,
  required bool isVideo,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surfaceDark,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _MediaSpecsSheet(path: path, isVideo: isVideo),
  );
}

class _MediaSpecsSheet extends ConsumerStatefulWidget {
  final String path;
  final bool isVideo;

  const _MediaSpecsSheet({required this.path, required this.isVideo});

  @override
  ConsumerState<_MediaSpecsSheet> createState() => _MediaSpecsSheetState();
}

class _MediaSpecsSheetState extends ConsumerState<_MediaSpecsSheet> {
  Map<String, dynamic>? _meta;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await ref
        .read(cinemaCameraRepositoryProvider)
        .inspectMediaMetadata(widget.path, isVideo: widget.isVideo);
    if (!mounted) return;
    setState(() {
      _meta = data;
      _loading = false;
    });
  }

  String _formatSize(num? kb) {
    if (kb == null || kb <= 0) return '—';
    if (kb >= 1024) return '${(kb / 1024).toStringAsFixed(2)} MB';
    return '${kb.round()} KB';
  }

  String _formatDuration(num? seconds) {
    if (seconds == null || seconds <= 0) return '—';
    final total = seconds.round();
    final mins = (total ~/ 60).toString().padLeft(2, '0');
    final secs = (total % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final meta = _meta ?? const <String, dynamic>{};

    final width = (meta['width'] as num?)?.round();
    final height = (meta['height'] as num?)?.round();
    final resolution = (width != null && height != null && width > 0)
        ? '$width × $height'
        : '—';

    final rows = <(String, String)>[
      if (widget.isVideo) ...[
        ('RESOLUTION', resolution),
        (
          'FPS',
          meta['fps'] is num
              ? '${(meta['fps'] as num).toStringAsFixed(1)} fps'
              : '—'
        ),
        ('DURATION', _formatDuration(meta['durationSeconds'] as num?)),
        ('CODEC', (meta['codec'] ?? '—').toString()),
        (
          'BITRATE',
          meta['bitrateMbps'] is num
              ? '${(meta['bitrateMbps'] as num).toStringAsFixed(1)} Mbps'
              : '—'
        ),
        ('FILE SIZE', _formatSize(meta['fileSizeKB'] as num?)),
      ] else ...[
        (
          'RESOLUTION',
          meta['megapixels'] is num
              ? '$resolution (${(meta['megapixels'] as num).toStringAsFixed(1)} MP)'
              : resolution
        ),
        if (meta['lens'] != null || meta['focalLength'] != null)
          (
            'LENS',
            meta['lens'] != null
                ? meta['lens'].toString()
                : '${meta['focalLength']} mm'
          ),
        if (meta['fNumber'] != null) ('APERTURE', 'f/${meta['fNumber']}'),
        if (meta['shutter'] != null) ('SHUTTER', meta['shutter'].toString()),
        if (meta['iso'] != null) ('ISO', 'ISO ${meta['iso']}'),
        if (meta['colorSpace'] != null)
          ('COLOR SPACE', meta['colorSpace'].toString()),
        if (meta['camera'] != null) ('CAMERA', meta['camera'].toString()),
        ('FILE SIZE', _formatSize(meta['fileSizeKB'] as num?)),
      ],
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
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
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  color: AppTheme.cinemaAmber,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  s.mediaInfo,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: CupertinoActivityIndicator(
                    color: AppTheme.cinemaAmber,
                  ),
                ),
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.cardDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.hairline),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Text(
                              rows[i].$1,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                rows[i].$2,
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.monoStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (i < rows.length - 1)
                        const Divider(
                          height: 1,
                          thickness: 0.7,
                          color: AppTheme.hairline,
                        ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

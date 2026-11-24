import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/routing/capture_args.dart';
import '../../../../core/theme/app_theme.dart';

class CapturedPreviewScreen extends StatefulWidget {
  final CapturedPreviewArgs args;

  const CapturedPreviewScreen({super.key, required this.args});

  @override
  State<CapturedPreviewScreen> createState() => _CapturedPreviewScreenState();
}

class _CapturedPreviewScreenState extends State<CapturedPreviewScreen> {
  VideoPlayerController? _videoController;
  bool _isVideoReady = false;
  bool _isInitializingVideo = false;
  bool _didEdit = false;
  String? _videoError;

  bool get _isVideo => widget.args.mediaType == MediaCaptureType.video;

  String? get _editablePath =>
      _isVideo ? widget.args.videoFilePath : widget.args.imageFilePath;

  @override
  void initState() {
    super.initState();
    if (_isVideo && widget.args.videoFilePath != null) {
      _initVideoPlayer(widget.args.videoFilePath!);
    }
  }

  @override
  void dispose() {
    _videoController?.pause();
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  Future<void> _initVideoPlayer(String path) async {
    if (_isInitializingVideo) return;
    _isInitializingVideo = true;

    final previous = _videoController;
    _videoController = null;

    if (mounted) {
      setState(() {
        _isVideoReady = false;
        _videoError = null;
      });
    }

    try {
      await previous?.pause();
      await previous?.dispose();
    } catch (_) {}

    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();

      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _videoController = controller;
        _isVideoReady = true;
        _videoError = null;
      });
    } catch (error) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _videoController = null;
        _isVideoReady = false;
        _videoError = _describeVideoError(error);
      });
    } finally {
      _isInitializingVideo = false;
    }
  }

  String _describeVideoError(Object error) {
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  void _close() {
    _videoController?.pause();
    context.pop(_didEdit ? true : null);
  }

  Future<void> _openEditor() async {
    final path = _editablePath;
    if (path == null) return;

    _videoController?.pause();
    final edited = await context.push<bool>(
      '/editor',
      extra: PhotoEditorArgs(path: path, isVideo: _isVideo),
    );
    if (!mounted) return;
    if (edited == true) {
      setState(() => _didEdit = true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              AppStrings.of(context).saveToGalleryOnly,
              style: const TextStyle(fontSize: 12),
            ),
            backgroundColor: AppTheme.cardDark,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundBlack,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back, color: Colors.white),
          onPressed: _close,
        ),
        title: Text(_isVideo ? s.video : s.photo),
        actions: [
          if (_editablePath != null)
            TextButton.icon(
              onPressed: _openEditor,
              icon: const Icon(
                Icons.tune_rounded,
                size: 16,
                color: AppTheme.cinemaAmber,
              ),
              label: Text(
                s.editMedia.toUpperCase(),
                style: const TextStyle(
                  color: AppTheme.cinemaAmber,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _isVideo
                      ? _buildVideoPreview(s)
                      : _buildPhotoPreview(),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.hairline),
              ),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.checkmark_seal_fill,
                    color: AppTheme.cinemaAmber,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${widget.args.tone.name.toUpperCase()}  ·  '
                      '${(widget.args.intensity * 100).round()}%'
                      '${widget.args.isAnamorphic ? '  ·  2.39:1' : ''}',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _close,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.cinemaAmber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    s.done.toUpperCase(),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoPreview() {
    final bytes = widget.args.imageBytes;
    if (bytes != null) {
      return InteractiveViewer(
        minScale: 1.0,
        maxScale: 5.0,
        child: Image.memory(bytes, fit: BoxFit.contain),
      );
    }

    final path = widget.args.imageFilePath;
    if (path != null) {
      return InteractiveViewer(
        minScale: 1.0,
        maxScale: 5.0,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: Colors.black,
            child: Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white38,
                size: 36,
              ),
            ),
          ),
        ),
      );
    }

    return const ColoredBox(color: Colors.black);
  }

  Widget _buildVideoPreview(AppStrings s) {
    if (_videoError != null) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.videocam_off_rounded,
                  color: Colors.white54,
                  size: 38,
                ),
                const SizedBox(height: 10),
                Text(
                  _videoError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () {
                    final path = widget.args.videoFilePath;
                    if (path != null) _initVideoPlayer(path);
                  },
                  child: Text(
                    s.retry,
                    style: const TextStyle(color: AppTheme.cinemaAmber),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final controller = _videoController;
    if (!_isVideoReady || controller == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: CupertinoActivityIndicator(color: AppTheme.cinemaAmber),
        ),
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            if (controller.value.isPlaying) {
              controller.pause();
            } else {
              controller.play();
            }
          });
        },
        child: Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(controller),
                if (!controller.value.isPlaying)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      CupertinoIcons.play_fill,
                      color: Colors.white,
                      size: 34,
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

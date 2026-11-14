import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
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
  String? _videoError;

  bool get _isVideo => widget.args.mediaType == MediaCaptureType.video;

  @override
  void initState() {
    super.initState();
    if (_isVideo && widget.args.videoFilePath != null) {
      _initVideoPlayer(widget.args.videoFilePath!);
    }
  }

  @override
  void dispose() {
    // Pause before disposing: leaving a player running while the camera
    // session is re-created is what made the preview keep "playing on its own".
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
    } catch (_) {
      // Ignore teardown failures of the previous controller.
    }

    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      // Muted playback keeps the iOS audio session on the camera capture
      // category instead of switching it to playback.
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
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back, color: Colors.white),
          onPressed: _close,
        ),
        title: Text(_isVideo ? 'CINEMA REEL' : 'CINEMA STILL'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: _isVideo
                      ? _buildVideoPreview()
                      : _buildPhotoPreview(),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppTheme.cinemaAmber.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.checkmark_seal_fill,
                    color: AppTheme.cinemaAmber,
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.args.imageBytes != null || _isVideo
                              ? 'Tersimpan di Apple Photos (${widget.args.tone.name})'
                              : 'Tersimpan di galeri CineLens (${widget.args.tone.name})',
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_isVideo ? 'Cinema Reel' : widget.args.tone.filmReference} • Intensitas ${(widget.args.intensity * 100).round()}% • ${widget.args.isAnamorphic ? '2.39:1' : 'Full'}',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoButton.filled(
                  onPressed: _close,
                  child: Text(
                    _isVideo ? 'Rekam Adegan Berikutnya' : 'Ambil Foto Lainnya',
                    style: const TextStyle(fontWeight: FontWeight.w600),
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
      return Image.memory(bytes, fit: BoxFit.contain);
    }

    final path = widget.args.imageFilePath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Text(
              'Foto tidak dapat dibuka.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
      );
    }

    return const ColoredBox(color: Colors.black);
  }

  Widget _buildVideoPreview() {
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
                  size: 42,
                ),
                const SizedBox(height: 12),
                Text(
                  'Video tidak dapat diputar.\n$_videoError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 14),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    final path = widget.args.videoFilePath;
                    if (path != null) _initVideoPlayer(path);
                  },
                  child: const Text(
                    'Coba lagi',
                    style: TextStyle(color: AppTheme.cinemaAmber),
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
                      size: 36,
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

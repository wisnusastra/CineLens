import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/routing/app_router.dart';
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

  @override
  void initState() {
    super.initState();
    if (widget.args.mediaType == MediaCaptureType.video &&
        widget.args.videoFilePath != null) {
      _initVideoPlayer(widget.args.videoFilePath!);
    }
  }

  Future<void> _initVideoPlayer(String path) async {
    final controller = VideoPlayerController.file(File(path));
    await controller.initialize();
    await controller.setLooping(true);
    await controller.play();
    if (mounted) {
      setState(() {
        _videoController = controller;
        _isVideoReady = true;
      });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.args.mediaType == MediaCaptureType.video;

    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(CupertinoIcons.back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: Text(isVideo ? 'CINEMA REEL • 24FPS' : 'CINEMA STILL'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: isVideo
                      ? _buildVideoPreview()
                      : Image.memory(
                          widget.args.imageBytes!,
                          fit: BoxFit.contain,
                        ),
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
                          'Tersimpan di Apple Photos (${widget.args.tone.name})',
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${isVideo ? '24fps Cinema Video' : widget.args.tone.filmReference} • Intensitas ${(widget.args.intensity * 100).round()}% • ${widget.args.isAnamorphic ? '2.39:1' : 'Full'}',
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
                  onPressed: () => context.pop(),
                  child: Text(
                    isVideo ? 'Rekam Adegan Berikutnya' : 'Ambil Foto Lainnya',
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

  Widget _buildVideoPreview() {
    final controller = _videoController;
    if (!_isVideoReady || controller == null) {
      return const Center(
        child: CupertinoActivityIndicator(color: AppTheme.cinemaAmber),
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          controller.value.isPlaying ? controller.pause() : controller.play();
        });
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
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
    );
  }
}

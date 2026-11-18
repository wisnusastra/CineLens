// lib/features/opening/presentation/screens/opening_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_theme.dart';

/// First-install opening clip.
///
/// The video is bundled as an app asset and played through `video_player` with
/// its volume forced to zero, so the opening is silent even though the source
/// file still carries an audio track. A versioned preference makes sure it is
/// shown only once; the user can also skip it at any time.
class OpeningScreen extends StatefulWidget {
  const OpeningScreen({super.key});

  @override
  State<OpeningScreen> createState() => _OpeningScreenState();
}

class _OpeningScreenState extends State<OpeningScreen> {
  static const String _asset =
      'assets/video/opening_cinelens.mp4';

  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    // The clip is 576×1024 portrait; keep the opening upright even if the user
    // rotates the phone while it plays.
    SystemChrome.setPreferredOrientations(AppConstants.portraitOnly);
    _startVideo();
  }

  Future<void> _startVideo() async {
    final controller = VideoPlayerController.asset(_asset);
    _controller = controller;
    await controller.setLooping(false);

    try {
      await controller.initialize();
      // Mute explicitly: the imported clip has an audio track, and the opening
      // must never make sound, including when the ringer is on.
      await controller.setVolume(0);
      if (!mounted) return;
      setState(() => _ready = true);
      controller.addListener(_onProgress);
      await controller.play();
    } catch (_) {
      // A broken asset must not trap the user in the opening screen.
      if (!mounted) return;
      setState(() {
        _failed = true;
        _ready = true;
      });
    }
  }

  void _onProgress() {
    final controller = _controller;
    if (controller == null || _finishing) return;
    if (!controller.value.isInitialized) return;

    final duration = controller.value.duration;
    final position = controller.value.position;
    if (duration > Duration.zero &&
        position >= duration - const Duration(milliseconds: 150)) {
      _finish();
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;

    final controller = _controller;
    controller?.removeListener(_onProgress);
    if (controller?.value.isInitialized ?? false) {
      await controller!.pause();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOpeningSeen, true);

    await SystemChrome.setPreferredOrientations(
      AppConstants.supportedOrientations,
    );

    if (!mounted) return;
    context.go('/');
  }

  @override
  void dispose() {
    _controller?.removeListener(_onProgress);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final hasVideo = _ready &&
        !_failed &&
        controller != null &&
        controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (hasVideo)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            )
          else if (_ready)
            const Center(
              child: Icon(
                Icons.movie_filter_outlined,
                color: Color(0xFF3A3A40),
                size: 72,
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: AppTheme.cinemaAmber),
            ),

          // Top bar: brand + skip.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Row(
                  children: [
                    const Text(
                      'CINELENS',
                      style: TextStyle(
                        color: AppTheme.cinemaAmber,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.4,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _finish,
                      child: const Text(
                        'LEWATI',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom call to action.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton(
                        onPressed: _finish,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.cinemaAmber,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'MULAI',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Opening hanya tampil sekali saat pertama kali membuka '
                      'CineLens.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

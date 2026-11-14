import 'dart:typed_data';
import 'package:go_router/go_router.dart';
import '../../features/cinema_camera/domain/entities/cinema_tone.dart';
import '../../features/cinema_camera/presentation/screens/camera_screen.dart';
import '../../features/cinema_camera/presentation/screens/captured_preview_screen.dart';

enum MediaCaptureType { photo, video }

class CapturedPreviewArgs {
  final MediaCaptureType mediaType;
  final Uint8List? imageBytes;
  final String? videoFilePath;
  final CinemaTone tone;
  final double intensity;
  final bool isAnamorphic;

  const CapturedPreviewArgs.photo({
    required Uint8List this.imageBytes,
    required this.tone,
    required this.intensity,
    required this.isAnamorphic,
  })  : mediaType = MediaCaptureType.photo,
        videoFilePath = null;

  const CapturedPreviewArgs.video({
    required String this.videoFilePath,
    required this.tone,
    required this.intensity,
    required this.isAnamorphic,
  })  : mediaType = MediaCaptureType.video,
        imageBytes = null;
}

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'camera',
      builder: (context, state) => const CameraScreen(),
    ),
    GoRoute(
      path: '/preview',
      name: 'preview',
      builder: (context, state) {
        final args = state.extra as CapturedPreviewArgs;
        return CapturedPreviewScreen(args: args);
      },
    ),
  ],
);

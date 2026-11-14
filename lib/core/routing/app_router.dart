import 'package:go_router/go_router.dart';

import '../../features/cinema_camera/presentation/screens/camera_screen.dart';
import '../../features/cinema_camera/presentation/screens/captured_preview_screen.dart';
import 'capture_args.dart';

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

import 'package:go_router/go_router.dart';

import '../../features/cinema_camera/presentation/screens/camera_screen.dart';
import '../../features/cinema_camera/presentation/screens/captured_gallery_screen.dart';
import '../../features/cinema_camera/presentation/screens/captured_preview_screen.dart';
import '../../features/opening/presentation/screens/opening_screen.dart';
import '../../features/photo_editor/presentation/screens/photo_editor_screen.dart';
import 'capture_args.dart';

/// Builds the router after `main` has checked whether this is a first launch.
///
/// The opening clip must be the very first screen on a fresh install, but it
/// should never appear again once the preference has been written.
GoRouter createAppRouter({required bool showOpening}) {
  return GoRouter(
    initialLocation: showOpening ? '/opening' : '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'camera',
        builder: (context, state) => const CameraScreen(),
      ),
      GoRoute(
        path: '/opening',
        name: 'opening',
        builder: (context, state) => const OpeningScreen(),
      ),
      GoRoute(
        path: '/preview',
        name: 'preview',
        builder: (context, state) {
          final args = state.extra as CapturedPreviewArgs;
          return CapturedPreviewScreen(args: args);
        },
      ),
      GoRoute(
        path: '/gallery',
        name: 'gallery',
        builder: (context, state) => const CapturedGalleryScreen(),
      ),
      GoRoute(
        path: '/editor',
        name: 'editor',
        builder: (context, state) {
          final args = state.extra as PhotoEditorArgs;
          return PhotoEditorScreen(args: args);
        },
      ),
    ],
  );
}

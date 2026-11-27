import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../../features/cinema_camera/presentation/screens/camera_screen.dart';
import '../../features/cinema_camera/presentation/screens/captured_gallery_screen.dart';
import '../../features/cinema_camera/presentation/screens/captured_preview_screen.dart';
import '../../features/opening/presentation/screens/opening_screen.dart';
import '../../features/photo_editor/presentation/screens/photo_editor_screen.dart';
import 'capture_args.dart';

/// Builds a silky 120Hz cinema modal transition (gentle zoom-in + easeOutCubic
/// fade) used when opening full-screen media preview or the Lightroom editor.
CustomTransitionPage<T> _cinemaFadeScalePage<T>({
  required GoRouterState state,
  required Widget child,
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.965, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

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
        pageBuilder: (context, state) => CupertinoPage<void>(
          key: state.pageKey,
          child: const CameraScreen(),
        ),
      ),
      GoRoute(
        path: '/opening',
        name: 'opening',
        pageBuilder: (context, state) => _cinemaFadeScalePage<void>(
          state: state,
          child: const OpeningScreen(),
        ),
      ),
      GoRoute(
        path: '/preview',
        name: 'preview',
        pageBuilder: (context, state) {
          final args = state.extra as CapturedPreviewArgs;
          return _cinemaFadeScalePage<bool?>(
            state: state,
            child: CapturedPreviewScreen(args: args),
          );
        },
      ),
      GoRoute(
        path: '/gallery',
        name: 'gallery',
        pageBuilder: (context, state) => CupertinoPage<void>(
          key: state.pageKey,
          child: const CapturedGalleryScreen(),
        ),
      ),
      GoRoute(
        path: '/editor',
        name: 'editor',
        pageBuilder: (context, state) {
          final args = state.extra as PhotoEditorArgs;
          return _cinemaFadeScalePage<bool?>(
            state: state,
            child: PhotoEditorScreen(args: args),
          );
        },
      ),
    ],
  );
}

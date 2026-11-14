// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants/app_constants.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations(
    AppConstants.supportedOrientations,
  );

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(
    const ProviderScope(
      child: CineLensApp(),
    ),
  );
}

class CineLensApp extends StatelessWidget {
  const CineLensApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CineLens iOS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkCinemaTheme,
      routerConfig: appRouter,
    );
  }
}

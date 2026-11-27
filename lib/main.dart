// lib/main.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/constants/app_constants.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Decide the very first route before the app is drawn: a fresh install gets
  // the silent opening clip, everyone else goes straight to the camera.
  final prefs = await SharedPreferences.getInstance();
  final showOpening =
      !(prefs.getBool(AppConstants.prefOpeningSeen) ?? false);

  await SystemChrome.setPreferredOrientations(
    AppConstants.supportedOrientations,
  );

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(
    ProviderScope(
      child: CineLensApp(
        router: createAppRouter(showOpening: showOpening),
      ),
    ),
  );
}

class CineLensApp extends StatelessWidget {
  final GoRouter router;

  const CineLensApp({super.key, required this.router});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CineLens',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkCinemaTheme,
      scrollBehavior: const CupertinoScrollBehavior(),
      supportedLocales: const <Locale>[
        Locale('en'),
        Locale('id'),
      ],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (locale, supported) {
        if (locale?.languageCode.toLowerCase() == 'id') {
          return const Locale('id');
        }
        return const Locale('en');
      },
      routerConfig: router,
    );
  }
}

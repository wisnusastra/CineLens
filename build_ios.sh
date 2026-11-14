#!/bin/bash
set -eo pipefail

trap 'echo "❌ GAGAL pada baris $LINENO (exit code:$?)"' ERR

echo "=== 0. Sinkronisasi Otomatis Seluruh File Dart CineLens iOS ==="
rm -rf lib/features
mkdir -p lib/features/about/presentation/screens
mkdir -p lib/features/cinema_camera/domain/entities
mkdir -p lib/features/cinema_camera/data/datasources
mkdir -p lib/features/cinema_camera/presentation/providers
mkdir -p lib/features/cinema_camera/presentation/screens

cat << 'DART_FILE_EOF' > lib/main.dart
// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/cinema_camera/presentation/screens/camera_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ProviderScope(child: CineLensApp()));
}

class CineLensApp extends StatelessWidget {
  const CineLensApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CineLens iOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.amber,
          brightness: Brightness.dark,
        ),
      ),
      home: const CameraScreen(),
    );
  }
}
DART_FILE_EOF

cat << 'DART_FILE_EOF' > lib/features/about/presentation/screens/about_screen.dart
// lib/features/about/presentation/screens/about_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String developerName = 'Wisnu Sastra Wijaya';
  static const String supportEmail = 'wisnusastra9@gmail.com';
  static const String appVersion = '1.1.0 ProRes';
  static const MethodChannel _channel =
      MethodChannel('com.cinelens.ios/native_camera');

  void _copyEmail(BuildContext context) {
    Clipboard.setData(const ClipboardData(text: supportEmail));
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Email $supportEmail berhasil disalin'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _sendFeedback() async {
    await _channel.invokeMethod<bool>('shareText', {
      'text': 'Halo $developerName,\n\n'
          'Saya ingin memberikan masukan / dukungan untuk aplikasi CineLens iOS:\n\n'
          '(Tulis pesan Anda di sini)\n\n'
          'Kirim ke: $supportEmail',
      'subject': 'CineLens iOS - Support & Masukan',
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E10),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('About CineLens'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.amberAccent, width: 1.5),
                    ),
                    child: const Icon(
                      Icons.camera_rounded,
                      color: Colors.amberAccent,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'CineLens iOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Native AVFoundation ProRes & Full-Sensor Cinema Camera',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Version $appVersion',
                      style: TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'DEVELOPER',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.amber.withValues(alpha: 0.2),
                        child: const Text(
                          'WS',
                          style: TextStyle(
                            color: Colors.amberAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              developerName,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Lead iOS & Flutter Developer',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SUPPORT & MASUKAN',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Punya ide fitur baru, laporan bug, atau ingin memberikan dukungan untuk pengembangan CineLens? Hubungi developer langsung melalui email di bawah ini:',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232329),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.email_outlined,

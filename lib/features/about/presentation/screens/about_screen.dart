// lib/features/about/presentation/screens/about_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String developerName = 'Wisnu Sastra Wijaya';
  static const String supportEmail = 'wisnusastra9@gmail.com';
  static const String appVersion = '1.0.3';

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

  void _sendFeedback() {
    Share.share(
      'Halo $developerName,\n\n'
      'Saya ingin memberikan masukan / dukungan untuk aplikasi CineLens iOS:\n\n'
      '(Tulis pesan Anda di sini)\n\n'
      'Kirim ke: $supportEmail',
      subject: 'CineLens iOS - Support & Masukan',
    );
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
            // Header Logo & Nama Aplikasi
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
                      color: Colors.amber.withOpacity(0.15),
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
                    'Cinematic Camera & Real-Time Color Grading',
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

            // Daftar perbaikan rilis ini
            // Container is not a const constructor, so the lint cannot apply.
            // ignore: prefer_const_constructors
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF18181C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PERUBAHAN TERBARU',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  SizedBox(height: 12),
                  _ChangeEntry(
                    title: 'Foto resolusi penuh',
                    detail:
                        'Foto kini memakai sensor penuh (bukan 1080p) dan '
                        'di-grading native sebagai JPEG kualitas 0.98.',
                  ),
                  _ChangeEntry(
                    title: 'Pilihan 1080p / 4K & 24 / 30 / 60 FPS',
                    detail:
                        'Profil video dibatasi 4K agar encoder iOS tetap stabil, '
                        'dengan bitrate 30–90 Mbps dan audio 192 kbps.',
                  ),
                  _ChangeEntry(
                    title: 'Stabilizer video aktif otomatis',
                    detail:
                        'iOS memilih mode stabilisasi terbaik yang didukung '
                        'format aktif (Cinematic / Standard). Statusnya tampil '
                        'di viewfinder dan menu opsi.',
                  ),
                  _ChangeEntry(
                    title: 'Preset lebih menyatu dengan hasil',
                    detail:
                        'Grading LUT kini dihitung di ruang warna sRGB yang sama '
                        'dengan pratinjau, jadi warna hasil foto dan video tidak '
                        'lagi berbeda dari layar.',
                  ),
                  _ChangeEntry(
                    title: 'Pinch zoom & galeri dalam aplikasi',
                    detail:
                        'Cubit layar untuk zoom dengan indikator, dan galeri '
                        'lokal untuk melihat atau menghapus hasil tanpa izin '
                        'Apple Photos.',
                  ),
                  _ChangeEntry(
                    title: 'Tray preset landscape bisa disembunyikan',
                    detail:
                        'Di mode landscape tray otomatis mengecil dan bisa '
                        'dibuka kembali lewat tombol palet.',
                    isLast: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Kartu Kredit Developer
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
                        backgroundColor: Colors.amber.withOpacity(0.2),
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

            // Kartu Support & Masukan
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
                          color: Colors.amberAccent,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: SelectableText(
                            supportEmail,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Salin Email',
                          onPressed: () => _copyEmail(context),
                          icon: const Icon(
                            Icons.copy_rounded,
                            color: Colors.white70,
                            size: 19,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => _copyEmail(context),
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          label: const Text('Salin Email'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _sendFeedback,
                          icon: const Icon(Icons.send_rounded, size: 18),
                          label: const Text(
                            'Kirim Masukan',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of the in-app changelog on the About screen.
class _ChangeEntry extends StatelessWidget {
  final String title;
  final String detail;
  final bool isLast;

  const _ChangeEntry({
    required this.title,
    required this.detail,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Icon(
              Icons.check_circle_rounded,
              color: Colors.amberAccent,
              size: 14,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

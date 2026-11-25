// lib/features/about/presentation/screens/about_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/l10n/app_strings.dart';
import '../../../../core/theme/app_theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String developerName = 'Wisnu Sastra Wijaya';
  static const String supportEmail = 'wisnusastra9@gmail.com';
  static const String appVersion = '2.4.1 PRO';

  void _copyEmail(BuildContext context, AppStrings s) {
    Clipboard.setData(const ClipboardData(text: supportEmail));
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${s.emailCopied}: $supportEmail',
            style: const TextStyle(fontSize: 12),
          ),
          backgroundColor: AppTheme.cardDark,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _sendFeedback(AppStrings s) {
    Share.share(
      s.isId
          ? 'Halo $developerName,\n\nMasukan untuk CineLens iOS ($appVersion):\n\n(Tulis pesan Anda)\n\nKontak: $supportEmail'
          : 'Hi $developerName,\n\nFeedback for CineLens iOS ($appVersion):\n\n(Write your message)\n\nContact: $supportEmail',
      subject: 'CineLens iOS $appVersion — Feedback',
    );
  }

  void _showChangelogSheet(BuildContext context, AppStrings s) {
    HapticFeedback.selectionClick();
    final isId = s.isId;

    final releases = <({String version, String tag, List<String> items})>[
      (
        version: 'v2.4.1 PRO',
        tag: isId ? 'TERBARU' : 'LATEST',
        items: isId
            ? const [
                'Fix Portrait Photo pakai Hardware LiDAR/Dual-Cam Depth (Apple CIDepthBlurEffect) agar bokeh alami tanpa halo cat air',
                'Fix Mode Cinematic Video patah-patah & hang (0.25× GPU blur, Vision .fast & async writer queue 1080p P3 HEVC)',
                'Foto standar kembali 100% tajam tanpa blur tepi tambahan + Deep Shadow bersih 0% grain',
              ]
            : const [
                'Fixed Portrait Photo to use real Hardware LiDAR/Dual-Cam Depth (Apple CIDepthBlurEffect) for natural optical falloff with zero watercolor halos',
                'Fixed Cinematic Video stutter & freeze (fast 0.25× GPU blur, .fast Vision segmentation & non-blocking async HEVC writer)',
                'Restored razor-sharp native Photo edge fidelity with clean 0%-grain deep shadows',
              ],
      ),
      (
        version: 'v2.4.0 PRO',
        tag: '48MP & BOKEH',
        items: isId
            ? const [
                'Deep Shadow jauh lebih bersih (0% grain di hitam pekat + Shadow-Only Chroma NR)',
                'Auto-Defringe optik & HEIF 10-Bit P3 efisien (~4–5 MB, kualitas 10-bit tetap penuh)',
                'Mode 48MP HI-RES (bypass Quad-Bayer / ProRAW 48MP) & tombol lensa 2× (48mm crop murni)',
                'Mode PORTRAIT (Foto Bokeh Optik f/1.4–f/16 via Vision AI + Film LUT & 10-Bit P3)',
                'Mode CINEMATIC (Video Bokeh Real-Time f/1.4–f/16 + Smooth Rack Focus + Direct 10-Bit P3 HEVC)',
              ]
            : const [
                'Cleaner deep shadows (0% ink-black grain + Shadow-Only Chroma Denoise)',
                'Optical micro-defringe & efficient 10-Bit Display P3 HEIF (~4–5 MB master)',
                '48MP HI-RES sensor bypass (ProRAW / Quad-Bayer 48MP) & 2× (48mm lossless crop) lens pill',
                'PORTRAIT Photo Mode (f/1.4–f/16 Optical Disc Bokeh via Vision Neural Engine + Film LUT)',
                'CINEMATIC Video Mode (Real-Time f/1.4–f/16 Bokeh + Smooth Rack Focus + 10-Bit P3 HEVC)',
              ],
      ),
      (
        version: 'v2.3.0 PRO',
        tag: 'OUTPUT & AI',
        items: isId
            ? const [
                'Fix Live Metal LUT layar hitam saat zoom 2× / pindah lensa',
                'Ekspor Master 10-Bit Display P3 HEIF & ACES Filmic Highlight Roll-Off',
                'Process Zero Night Stack (fusi 3× Bayer RAW 16-bit tanpa efek minyak)',
                'Silver-Halide Grain berbasis luminansi, Color Density & Skin Protection',
                'Offline Vision AI Smart Masking (+ Subject AI & + Sky / BG AI)',
                'Ekspor 3D LUT (.cube 33³) dari Editor langsung ke Kamera atau Share',
                'Bingkai Film Vintage (Leica, Dark Matte, 35mm, Polaroid) + EXIF & Tanggal',
                'Gallery Video Poster Thumbnail, Edit Massal, Timeline Scrub & Info EXIF',
                'Self-Timer (3s/10s), Shutter Tombol Volume/Bluetooth & Pemilih Mic Eksternal',
              ]
            : const [
                'Fixed Live Metal LUT black screen when zooming 2× or switching lenses',
                '10-Bit Display P3 HEIF export & ACES/AgX Filmic Highlight Roll-Off',
                'Process Zero Night Stack (3× 16-bit Bayer RAW fusion, zero Smart HDR oil)',
                'Luminance-weighted Silver-Halide Grain, Color Density & Skin Protection',
                'Offline Vision AI Smart Masking (+ Subject AI & + Sky / BG AI)',
                'Export 33³ .cube 3D LUT from Editor straight to Camera or Share',
                'Vintage Film Borders (Leica, Dark Matte, 35mm, Polaroid) + EXIF & Date Stamp',
                'Gallery Video Poster Thumbnails, Batch Edit, Live Video Scrub & EXIF Specs',
                'Self-Timer (3s/10s), Volume/Bluetooth Remote Shutter & External Mic Picker',
              ],
      ),
      (
        version: 'v2.2.0 PRO',
        tag: 'UI & OPENFILM',
        items: isId
            ? const [
                'Rombak UI Pro Obsidian Matte × Cinema Amber & auto-bahasa OS (ID/EN)',
                'Multi-Select Gallery (Hapus & Simpan Massal) & Rasio Frame Vintage (1:1–XPan)',
                'Live Metal 60fps LUT Viewfinder, Direct HEVC LUT Rec & Simpan RAW DNG',
                'Multi-Log IDT (Apple/S-Log3/D-Log M/C-Log3/F-Log2), Color Match & 3-Mode Scopes',
                'DOP Overlays (Focus Peaking, Zebra, False Color, Horizon, Audio dB, Live Scope)',
              ]
            : const [
                'Pro Obsidian Matte × Cinema Amber UI redesign with OS language detection',
                'Gallery Multi-Select Batch Delete/Save & Vintage Frame Ratios (1:1–XPan)',
                'Live Metal 60fps LUT Viewfinder, Direct HEVC LUT Rec & Save DNG RAW',
                'Multi-Log IDT (Apple/S-Log3/D-Log M/C-Log3/F-Log2), Color Match & 3-Mode Scopes',
                'DOP Overlays (Focus Peaking, Zebra, False Color, Horizon, Audio dB, Live Scope)',
              ],
      ),
      (
        version: 'v2.1.0 PRO',
        tag: 'EDITOR & RAW',
        items: isId
            ? const [
                'Process Zero Bayer RAW pipeline anti oil-painting + Optical Multi-Lens',
                'Editor 16-bit lengkap ala Lightroom (Kurva, 8-band HSL, 3-Way Grading, Bokeh, Mask)',
                'Undo/Redo 40 langkah, Auto Tone, Copy/Paste Edit & Simpan Preset',
              ]
            : const [
                'Process Zero Bayer RAW capture pipeline + Optical Multi-Lens switcher',
                'Full 16-bit Lightroom-class editor (Curves, 8-band HSL, 3-Way Wheels, Bokeh, Masks)',
                '40-step Undo/Redo, Auto Tone, Copy/Paste Settings & Saved Presets',
              ],
      ),
      (
        version: 'v2.0.0 PRO',
        tag: 'CORE ENGINE',
        items: isId
            ? const [
                '18 Stok Film 33³ Core Image native + Impor LUT .cube',
                'Kontrol manual sensor penuh (Shutter, ISO, WB Kelvin, Focus) & 180° Rule',
                'Apple Log, ProRes 422 10-bit, dan Impor Media dari Apple Photos',
              ]
            : const [
                '18 Native 33³ Core Image Film Stocks + Custom .cube LUT Import',
                'Full manual sensor controls (Shutter, ISO, WB Kelvin, Focus) & 180° Rule',
                'Apple Log, ProRes 422 10-bit & Apple Photos Media Import',
              ],
      ),
    ];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetCtx) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.78,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 14, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.history_rounded,
                      color: AppTheme.cinemaAmber,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      s.changelogTitle,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.textSecondary,
                        size: 20,
                      ),
                      onPressed: () => Navigator.of(sheetCtx).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 0.7, color: AppTheme.hairline),
              Flexible(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
                  itemCount: releases.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (_, idx) {
                    final rel = releases[idx];
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.cardDark,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: idx == 0
                              ? AppTheme.cinemaAmber.withValues(alpha: 0.45)
                              : AppTheme.hairline,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                rel.version,
                                style: AppTheme.monoStyle(
                                  color: idx == 0
                                      ? AppTheme.cinemaAmber
                                      : AppTheme.textPrimary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: idx == 0
                                      ? AppTheme.cinemaAmber
                                          .withValues(alpha: 0.16)
                                      : Colors.white.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  rel.tag,
                                  style: TextStyle(
                                    color: idx == 0
                                        ? AppTheme.cinemaAmber
                                        : AppTheme.textSecondary,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          for (final line in rel.items)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Padding(
                                    padding: EdgeInsets.only(top: 5, right: 8),
                                    child: Icon(
                                      Icons.circle,
                                      size: 4.5,
                                      color: AppTheme.cinemaAmber,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      line,
                                      style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 11.5,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Scaffold(
      backgroundColor: AppTheme.backgroundBlack,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundBlack,
        title: Text(s.aboutApp.toUpperCase()),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // Hero Brand Card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppTheme.hairline),
              ),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.cinemaAmber.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppTheme.cinemaAmber.withValues(alpha: 0.7),
                        width: 1.4,
                      ),
                    ),
                    child: const Icon(
                      Icons.camera_rounded,
                      color: AppTheme.cinemaAmber,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'CineLens iOS',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.isId
                        ? 'Kamera Sinema 16-Bit & Studio Color Grading'
                        : '16-Bit Cinema Camera & Color Grading Studio',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.cinemaAmber.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppTheme.cinemaAmber.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      'v$appVersion',
                      style: AppTheme.monoStyle(
                        color: AppTheme.cinemaAmber,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Collapsible Changelog Action Button (details shown only on tap)
            InkWell(
              onTap: () => _showChangelogSheet(context, s),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceDark,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.cinemaAmber.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: AppTheme.cinemaAmber.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(
                        Icons.history_rounded,
                        color: AppTheme.cinemaAmber,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.changelogBtn,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'v$appVersion · ${s.isId ? 'Ketuk untuk detail pembaruan' : 'Tap to view release notes'}',
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.cinemaAmber,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Developer Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'DEVELOPER',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 21,
                        backgroundColor:
                            AppTheme.cinemaAmber.withValues(alpha: 0.16),
                        child: Text(
                          'WS',
                          style: AppTheme.monoStyle(
                            color: AppTheme.cinemaAmber,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              developerName,
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.isId
                                  ? 'Kreator & Pengembang CineLens iOS'
                                  : 'Creator & Developer of CineLens iOS',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 11.5,
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
            const SizedBox(height: 14),

            // Support & Feedback Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceDark,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.supportTitle,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(
                        Icons.mail_outline_rounded,
                        color: AppTheme.cinemaAmber,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        supportEmail,
                        style: AppTheme.monoStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _copyEmail(context, s),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.textPrimary,
                            side: const BorderSide(color: AppTheme.hairline),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Icons.copy_rounded, size: 15),
                          label: Text(
                            s.copyEmail,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _sendFeedback(s),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.cinemaAmber,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Icons.send_rounded, size: 15),
                          label: Text(
                            s.sendFeedback,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
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

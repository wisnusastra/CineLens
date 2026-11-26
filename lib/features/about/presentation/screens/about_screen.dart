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
  static const String appVersion = '3.5.1 PRO';

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
        version: 'v3.5.1 PRO',
        tag: isId ? 'TERBARU' : 'LATEST',
        items: isId
            ? const [
                'Fix warna kulit terlalu oranye pada Orange & Teal, Metro Teal Night & Blue Hour Rooftop: perlindungan Skin-Vector penuh untuk cahaya indoor/daylight sambil mempertahankan Petrol Teal (#005F60/#008083/#249EA0) yang tajam',
                'Fix Resep C1–C4: tambah tombol STD di kiri strip resep + tap ulang slot aktif untuk langsung mematikan resep & kembali ke Standar',
                'Akses Watermark Frame 1-Tap: tombol WM langsung di viewfinder kamera + tab khusus "Watermark" di bar bawah Gallery Photo Editor',
              ]
            : const [
                'Fixed over-orange indoor skin tones on Orange & Teal, Metro Teal Night & Blue Hour Rooftop with full Skin-Vector protection while keeping crisp Petrol Teal separation',
                'Fixed C1–C4 Recipes toggle-off: added STD reset pill and tapping the active recipe slot now cleanly turns it off back to Standard',
                'Added 1-tap WM button directly on the camera viewfinder and a dedicated Watermark tab in the Gallery Photo Editor',
              ],
      ),
      (
        version: 'v3.5.0 PRO',
        tag: 'WATERMARK',
        items: isId
            ? const [
                'Watermark Frame Studio (12 Gaya Editorial & Film): deteksi otomatis model iPhone/kamera asli (mis. iPhone 14 Pro Max) + EXIF 2 baris (24mm f/1.8 / 1/250s ISO 100) + pilihan tema White | Black | Glass',
                'Kategori Signature Cinema (Classic Bar, Side Strip, Gallery Frame, Corner Glass), Film Heritage (35mm Kodak, 120 Medium Format, Director Slate, Polaroid) & Minimal — tersedia langsung di Kamera (auto-stamp saat foto) maupun Gallery Editor',
              ]
            : const [
                'Watermark Frame Studio (12 Editorial & Film Styles): automatic iPhone/camera model detection (e.g. iPhone 14 Pro Max) + 2-line EXIF specs (24mm f/1.8 / 1/250s ISO 100) + White | Black | Glass themes',
                'Grouped into Signature Cinema (Classic Bar, Side Strip, Gallery Frame, Corner Glass), Film Heritage (35mm Kodak, 120 Medium Format, Director Slate, Polaroid) & Minimal — available both as live Camera auto-watermark and in Gallery Editor',
              ],
      ),
      (
        version: 'v3.4.0 PRO',
        tag: 'COLOR & PRO',
        items: isId
            ? const [
                'Rombak total 3D LUT Orange & Teal sesuai palet sinema asli (#FD5901/#F78104/#FAAB36 × #249EA0/#008083/#005F60) + 5 Film Stock Cool Non-Warm baru: Metro Teal Night, Blue Hour Rooftop, Nordic Slate, Tokyo Petrol 500T & Cool Chrome 100',
                'Kamera Pro Baru: tekan-tahan AE/AF LOCK + geser vertikal EV langsung di layar, Resep Cepat C1–C4 (tap muat, tahan simpan), Pin Favorit LUT (★), fokal lensa asli 13·24·35·48·77mm, Pause/Resume Video + Timecode SMPTE + sisa storage, Timelapse 4K (1s–10s), Live Split RAW|LUT & Zen Mode',
                'Gallery & Editor Baru: 4K Frame Grab langsung dari video, Signature Fotografer kustom permanen + EXIF otomatis pada Frame Vintage, serta 1-Tap Social Export Safe sRGB (IG 4:5, Reels 9:16, WA HD)',
              ]
            : const [
                'Overhauled 3D LUT Orange & Teal calibrated to exact cinema palette (#FD5901/#F78104/#FAAB36 × #249EA0/#008083/#005F60) + 5 new Cool/Non-Warm Film Stocks: Metro Teal Night, Blue Hour Rooftop, Nordic Slate, Tokyo Petrol 500T & Cool Chrome 100',
                'Pro Camera Upgrades: Long-Press AE/AF LOCK + vertical EV swipe on viewfinder, C1–C4 Film Recipes, Pin Favorite LUTs (★), true 13·24·35·48·77mm focal pills, Pause/Resume Video + SMPTE Timecode + storage estimate, 4K Timelapse (1s–10s), Live Split RAW|LUT & Zen Mode',
                'Gallery & Editor Upgrades: 4K Still Frame Grab from Video, saved custom Photographer Signature + auto-EXIF on Vintage Frames, and 1-Tap Safe sRGB Social Export (IG 4:5, Reels 9:16, WA HD)',
              ],
      ),
      (
        version: 'v3.3.0 PRO',
        tag: 'PURE ENGINE',
        items: isId
            ? const [
                'Fokus penuh ke 2 mode utama PHOTO & VIDEO yang super stabil, cepat, dan bebas error (hapus mode Portrait & Cinematic dari kamera beserta overhead sensor LiDAR/virtual camera)',
                'Lensa fisik 0.5× · 1× · 2× · 3× selalu terkunci murni tanpa pindah otomatis ke makro 14mm; efek blur/bokeh optik tetap tersedia di Gallery Photo Editor',
              ]
            : const [
                'Streamlined into a rock-solid, ultra-fast 2-mode Pro Cinema Camera (PHOTO | VIDEO), removing Portrait & Cinematic modes along with LiDAR/virtual-camera overhead',
                'Discrete physical lenses (0.5× · 1× · 2× · 3×) always stay cleanly locked with zero macro hijack; optical Lens Blur / Bokeh remains available in the Gallery Photo Editor',
              ],
      ),
      (
        version: 'v3.2.0 PRO',
        tag: 'LANDSCAPE',
        items: isId
            ? const [
                'Fix mode Landscape miring 90°: rotasi otomatis 4 arah real-time untuk preview kamera, sensor LiDAR, hasil foto/video, dan titik tap-to-focus',
                'Rombak total UI Landscape 3 kolom ala Blackmagic Camera (Rail Kiri: Grid/Flash/Timer/HL/180°, Tengah: Viewfinder bebas hambatan + pill Lensa/Mode/LUT lipat, Rail Kanan: Shutter jempol + M + Flip + Galeri) aman dari Dynamic Island & nol tombol bertumpuk',
              ]
            : const [
                'Fixed sideways 90° Landscape camera preview: full real-time 4-orientation tracking for live preview, LiDAR depth, still/video capture, and tap-to-focus coordinates',
                'Complete 3-column Pro Landscape UI redesign (Left Tools Rail, Unobstructed Center Viewfinder + collapsible LUT tray, Right Thumb Shutter Grip) with Dynamic Island SafeArea and zero overlapping controls',
              ],
      ),
      (
        version: 'v3.1.3 PRO',
        tag: 'RECOVERY',
        items: isId
            ? const [
                'Fix error no_frames / kamera berhenti setelah putar preview video (hapus bentrok AVAudioRecorder kedua & auto-resume sesi kamera saat kembali dari Preview/Galeri atau selesai interupsi iOS)',
                'Upgrade bokeh Cinematic f/1.4–f/2.0 lebih creamy di latar belakang jauh sambil menjaga tepi subjek tetap super tajam',
              ]
            : const [
                'Fixed no_frames / stalled camera after returning from video preview (removed competing AVAudioRecorder & added automatic AVCaptureSession recovery on interruption/route return)',
                'Enhanced Cinematic Video f/1.4–f/2.0 deep background creaminess while keeping razor-sharp subject edges',
              ],
      ),
      (
        version: 'v3.1.2 PRO',
        tag: 'DOF & AF',
        items: isId
            ? const [
                'Fix Cinematic Video blur memotong objek dekat (kurva LiDAR DOF dilebarkan hingga 28 cm + feather 5px agar gelas/objek utuh tajam dari atas ke bawah)',
                'Aktifkan Smooth Continuous Autofocus otomatis saat masuk mode Video/Cinematic (lensa langsung tajam dari detik ke-0 tanpa perlu tap dulu)',
              ]
            : const [
                'Refined Cinematic Video LiDAR DOF curve (uncapped down to 28cm + softer 5px mask feather so close subjects stay sharp top-to-bottom with zero slice line)',
                'Enabled instant Smooth Continuous Autofocus on Video/Cinematic entry so the lens locks sharp from frame 1',
              ],
      ),
      (
        version: 'v3.1.1 PRO',
        tag: 'ROTATION & REC',
        items: isId
            ? const [
                'Fix Portrait Photo miring 90° & ketarik (apply EXIF orientation asli pada output Apple CIDepthBlurEffect)',
                'Fix gagal rekam Cinematic & error "Recording already active" (pisah delegate LiDAR depth dari videoOutput agar 24fps & LiDAR 30fps tidak deadlock + auto-reset watchdog)',
              ]
            : const [
                'Fixed Portrait Photo rotated 90° and stretched (properly applies EXIF orientation to Apple CIDepthBlurEffect output)',
                'Fixed Cinematic Video recording failure & "Recording already active" lock by decoupling LiDAR depth delegate from videoOutput (zero 24fps-vs-30fps deadlock) + auto-reset watchdog',
              ],
      ),
      (
        version: 'v3.1.0 PRO',
        tag: 'LiDAR & SPEED',
        items: isId
            ? const [
                'Fix Portrait Photo anti-loncat lensa 14mm makro: kunci sensor Hardware LiDAR 24mm + autofocus plane CIDepthBlurEffect asli',
                'Fix Cinematic Video LiDAR Z-Depth aktif 100% (format 1080p inputPriority + DisparityFloat32, auto-track subjek & bokeh optik 2-tier progresif)',
                'Fix stabilizer delay video: ganti mode .cinematic (delay ~0.8s) ke .standard (OIS+EIS zero-delay)',
                'Fix lag saat pertama buka aplikasi: bangun LUT 3D asinkron di background, pasang mikrofon hanya saat mode Video, dan paralelkan init Dart',
              ]
            : const [
                'Fixed Portrait Photo 14mm UltraWide macro hijack: prioritizes dedicated 24mm LiDAR depth camera & preserves native CIDepthBlurEffect AF plane',
                'Fixed Cinematic Video hardware LiDAR depth stream via explicit inputPriority 1080p DisparityFloat32 format + live subject auto-tracking & 2-tier progressive bokeh',
                'Eliminated ~0.8s video stabilizer preview lag by switching from .cinematic buffering to zero-delay .standard OIS+EIS',
                'Eliminated cold-launch lag via async background 3D LUT build, lazy microphone session attach, and parallel Dart startup',
              ],
      ),
      (
        version: 'v3.0.1 PRO',
        tag: '60FPS FIX',
        items: isId
            ? const [
                'Fix preview kamera patah-patah & berat: Zero-Copy IOSurface 60fps pass-through (< 0.1ms/frame) untuk viewfinder standar',
                'Dedicated 8-bit Metal previewContext tanpa Lanczos/RGBAh (10× lebih ringan & mulus di Live Metal LUT dan Cinematic Video)',
                'Matikan buffer stabilisasi video di mode Foto/Portrait agar viewfinder zero-latency',
              ]
            : const [
                'Fixed choppy/heavy camera preview via Zero-Copy IOSurface 60fps pass-through (< 0.1ms/frame) for standard viewfinder',
                'Added dedicated 8-bit Metal previewContext without RGBAh/Lanczos overhead (~10× faster Live Metal LUT & Cinematic Video)',
                'Disabled multi-frame video stabilization latency on Photo & Portrait viewfinders',
              ],
      ),
      (
        version: 'v3.0.0 PRO',
        tag: 'NATIVE ENGINE',
        items: isId
            ? const [
                'Mesin Kamera 100% Native Swift (AVFoundation + Metal GPU 60fps), tanpa plugin kamera Flutter',
                'Mode PORTRAIT pakai Sensor Hardware LiDAR / TripleCamera + Apple CIDepthBlurEffect asli (bokeh optik alami tanpa halo cat air)',
                'Mode CINEMATIC Video pakai Hardware LiDAR Z-Depth real-time + Smooth Rack Focus ke objek apa pun (tanpa patah-patah)',
                'Rekam Video + Audio dalam 1 sesi tunggal (tidak lagi terputus di 0.1 detik, simpan instan HEVC Display P3 + AAC 192kbps)',
                'Manajemen RAM super aman (autoreleasepool + CIContext.clearCaches) — anti hang / Jetsam OOM meski foto 48MP berulang kali',
              ]
            : const [
                '100% Native Swift Single-Session Camera Engine (AVFoundation + 60fps Metal GPU), completely removing the Flutter camera plugin',
                'True Hardware LiDAR / TripleCamera PORTRAIT Photo depth via Apple CIDepthBlurEffect (natural optical falloff, zero watercolor halo)',
                'True Hardware LiDAR Z-Depth CINEMATIC Video with smooth real-time Rack Focus on any subject and stutter-free recording',
                'Unified single-session Video + Audio recording (fixes 0.125s cutoff, instant Display P3 HEVC + 192kbps AAC save)',
                'Ultra-safe RAM pipeline (autoreleasepool + CIContext.clearCaches) preventing Jetsam OOM hangs across consecutive 48MP captures',
              ],
      ),
      (
        version: 'v2.4.1 PRO',
        tag: 'DEPTH FIX',
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

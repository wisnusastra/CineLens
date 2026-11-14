import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/cinema_tone.dart';
import '../providers/cinema_camera_provider.dart';

enum _LibraryTab { exportShare, importJson }

class PresetLibraryIoSheet extends ConsumerStatefulWidget {
  const PresetLibraryIoSheet({super.key});

  @override
  ConsumerState<PresetLibraryIoSheet> createState() =>
      _PresetLibraryIoSheetState();
}

class _PresetLibraryIoSheetState extends ConsumerState<PresetLibraryIoSheet> {
  _LibraryTab _activeTab = _LibraryTab.exportShare;
  final TextEditingController _jsonPasteController = TextEditingController();

  bool _isBusy = false;
  String? _statusMessage;
  bool _isErrorStatus = false;

  @override
  void dispose() {
    _jsonPasteController.dispose();
    super.dispose();
  }

  Rect _shareOriginFromContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return const Rect.fromLTWH(0, 0, 100, 100);
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _setFeedback(String message, {bool isError = false}) {
    setState(() {
      _statusMessage = message;
      _isErrorStatus = isError;
    });
  }

  Future<void> _handleExportSingle(BuildContext btnContext, CinemaTone tone) async {
    setState(() => _isBusy = true);
    try {
      await ref.read(cinemaCameraProvider.notifier).exportSingleTone(
            tone,
            shareOriginRect: _shareOriginFromContext(btnContext),
          );
      _setFeedback('File "${tone.name}.json" siap dibagikan.');
    } catch (e) {
      _setFeedback('Gagal mengekspor preset: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handleExportAllCustom(BuildContext btnContext) async {
    setState(() => _isBusy = true);
    try {
      await ref.read(cinemaCameraProvider.notifier).exportAllCustomTones(
            shareOriginRect: _shareOriginFromContext(btnContext),
          );
      _setFeedback('Semua preset kustom berhasil dikemas ke .json.');
    } catch (e) {
      _setFeedback('$e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handleCopyJson(CinemaTone tone) async {
    final jsonText =
        ref.read(cinemaCameraProvider.notifier).getToneJsonString(tone);
    await Clipboard.setData(ClipboardData(text: jsonText));
    HapticFeedback.mediumImpact();
    _setFeedback('JSON "${tone.name}" disalin ke Clipboard.');
  }

  Future<void> _handleImportFromFile() async {
    setState(() => _isBusy = true);
    try {
      final count =
          await ref.read(cinemaCameraProvider.notifier).importTonesFromFile();
      if (count > 0 && mounted) {
        HapticFeedback.heavyImpact();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$count preset sinematik berhasil diimpor & diterapkan!'),
          ),
        );
      }
    } on FormatException catch (e) {
      _setFeedback(e.message, isError: true);
    } catch (e) {
      _setFeedback('Gagal mengimpor file JSON: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _handleImportFromText() async {
    final raw = _jsonPasteController.text;
    if (raw.trim().isEmpty) {
      _setFeedback('Tempelkan kode JSON preset terlebih dahulu.', isError: true);
      return;
    }

    setState(() => _isBusy = true);
    try {
      final count = await ref
          .read(cinemaCameraProvider.notifier)
          .importTonesFromJsonText(raw);
      if (count > 0 && mounted) {
        HapticFeedback.heavyImpact();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$count preset sinematik berhasil diimpor & diterapkan!'),
          ),
        );
      }
    } on FormatException catch (e) {
      _setFeedback(e.message, isError: true);
    } catch (e) {
      _setFeedback('Gagal memproses JSON: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = ref.watch(cinemaCameraProvider).valueOrNull;
    final allTones = cameraState?.tones ?? [];
    final customTones = allTones.where((t) => t.isCustom).toList();
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 24 + bottomInset),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(
          color: AppTheme.cinemaAmber.withValues(alpha: 0.35),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'LUT PRESET SHARE & IMPORT',
                  style: TextStyle(
                    color: AppTheme.cinemaAmber,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Tutup',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            CupertinoSlidingSegmentedControl<_LibraryTab>(
              groupValue: _activeTab,
              backgroundColor: AppTheme.backgroundBlack,
              thumbColor: AppTheme.cinemaAmber,
              onValueChanged: (tab) {
                if (tab != null) {
                  setState(() {
                    _activeTab = tab;
                    _statusMessage = null;
                  });
                }
              },
              children: {
                _LibraryTab.exportShare: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'EXPORT / BAGIKAN',
                    style: TextStyle(
                      color: _activeTab == _LibraryTab.exportShare
                          ? Colors.black
                          : Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _LibraryTab.importJson: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'IMPORT JSON',
                    style: TextStyle(
                      color: _activeTab == _LibraryTab.importJson
                          ? Colors.black
                          : Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              },
            ),

            const SizedBox(height: 14),

            if (_statusMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _isErrorStatus
                      ? Colors.redAccent.withValues(alpha: 0.16)
                      : AppTheme.cinemaAmber.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _isErrorStatus
                        ? Colors.redAccent
                        : AppTheme.cinemaAmber,
                  ),
                ),
                child: Text(
                  _statusMessage!,
                  style: TextStyle(
                    color: _isErrorStatus
                        ? Colors.redAccent
                        : AppTheme.cinemaAmber,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (_activeTab == _LibraryTab.exportShare)
              _buildExportTab(customTones, cameraState?.selectedTone)
            else
              _buildImportTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildExportTab(List<CinemaTone> customTones, CinemaTone? activeTone) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (customTones.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.backgroundBlack,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                const Text(
                  'Belum ada preset kustom buatan Anda.\nBuat melalui "+ CUSTOM" atau bagikan tone yang sedang aktif:',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
                if (activeTone != null) ...[
                  const SizedBox(height: 12),
                  Builder(
                    builder: (btnCtx) => CupertinoButton(
                      color: AppTheme.surfaceDark,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      onPressed: _isBusy
                          ? null
                          : () => _handleExportSingle(btnCtx, activeTone),
                      child: Text(
                        'Bagikan Tone Aktif (${activeTone.name})',
                        style: const TextStyle(
                          color: AppTheme.cinemaAmber,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          )
        else ...[
          Builder(
            builder: (btnCtx) => CupertinoButton.filled(
              onPressed: _isBusy ? null : () => _handleExportAllCustom(btnCtx),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(CupertinoIcons.share, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Bagikan Semua Custom (${customTones.length} Preset .json)',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'DAFTAR CUSTOM PRESET ANDA',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: customTones.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final tone = customTones[index];
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundBlack,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: tone.accentColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tone.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              tone.filmReference,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Salin JSON',
                        onPressed: () => _handleCopyJson(tone),
                        icon: const Icon(
                          CupertinoIcons.doc_on_clipboard,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ),
                      Builder(
                        builder: (btnCtx) => IconButton(
                          tooltip: 'Bagikan File .json',
                          onPressed: _isBusy
                              ? null
                              : () => _handleExportSingle(btnCtx, tone),
                          icon: const Icon(
                            CupertinoIcons.share_up,
                            color: AppTheme.cinemaAmber,
                            size: 21,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildImportTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CupertinoButton.filled(
          onPressed: _isBusy ? null : _handleImportFromFile,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isBusy)
                const CupertinoActivityIndicator(color: Colors.black)
              else
                const Icon(CupertinoIcons.folder_open, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Pilih File .JSON (iOS Files / iCloud)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'ATAU TEMPEL KODE JSON PRESET',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  _jsonPasteController.text = data!.text!;
                }
              },
              child: const Text(
                'Tempel dari Clipboard',
                style: TextStyle(color: AppTheme.cinemaAmber, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        CupertinoTextField(
          controller: _jsonPasteController,
          maxLines: 5,
          placeholder: '{"app": "CineLens iOS", "presets": [ ... ]}',
          placeholderStyle: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            fontFamily: 'Courier',
          ),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'Courier',
          ),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.backgroundBlack,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
        ),
        const SizedBox(height: 12),
        CupertinoButton(
          color: AppTheme.backgroundBlack,
          onPressed: _isBusy ? null : _handleImportFromText,
          child: const Text(
            'Impor & Terapkan Kode JSON',
            style: TextStyle(
              color: AppTheme.cinemaAmber,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

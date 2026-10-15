import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:platform_services/platform_services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app.dart';
import '../error_messages.dart';

/// The generate tab: type or paste text, render a QR code, save or share it.
class GeneratePage extends StatefulWidget {
  const GeneratePage({super.key});

  @override
  State<GeneratePage> createState() => _GeneratePageState();
}

class _GeneratePageState extends State<GeneratePage> {
  /// Highest byte count a QR symbol can hold in byte mode at error-correction
  /// level M (version 40). Checked before rendering so oversized input produces
  /// a clear message rather than an exception from the encoder (project spec §7.2).
  static const int _maxPayloadBytes = 2331;

  /// Rasterisation factor when exporting. 3x keeps a 280dp code at ~840px,
  /// which is comfortably above the resolution a reader needs (§7.2).
  static const double _exportPixelRatio = 3.0;

  final TextEditingController _input = TextEditingController();
  final GlobalKey _qrBoundaryKey = GlobalKey();
  final GlobalKey _shareOriginKey = GlobalKey();

  String? _generatedData;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _notify(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pasteFromClipboard() async {
    // The clipboard is read only on this explicit user action (project spec §11).
    final String? text;
    try {
      text = await AppScope.of(context).clipboard.readText();
    } catch (_) {
      _notify('无法读取剪贴板');
      return;
    }
    if (!mounted) {
      return;
    }
    if (text == null || text.trim().isEmpty) {
      _notify('剪贴板为空');
      return;
    }
    _input.text = text;
    // Keeps the trailing part of long pasted content visible.
    _input.selection = TextSelection.collapsed(offset: text.length);
    setState(() {
      _generatedData = null;
      _error = null;
    });
  }

  void _generate() {
    final text = _input.text;
    if (text.trim().isEmpty) {
      _notify('请输入要生成二维码的内容');
      return;
    }

    final byteLength = utf8.encode(text).length;
    if (byteLength > _maxPayloadBytes) {
      setState(() {
        _generatedData = null;
        _error = '内容过长：$byteLength 字节，二维码最多支持 $_maxPayloadBytes 字节。';
      });
      return;
    }

    setState(() {
      _generatedData = text;
      _error = null;
    });
  }

  void _clear() {
    _input.clear();
    setState(() {
      _generatedData = null;
      _error = null;
    });
  }

  /// Renders the on-screen QR widget to a PNG.
  ///
  /// Capturing the widget rather than re-encoding guarantees the saved image is
  /// exactly what the user sees.
  Future<Uint8List?> _renderQrPng() async {
    final boundary =
        _qrBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return null;
    }
    final image = await boundary.toImage(pixelRatio: _exportPixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _saveToGallery() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await _renderQrPng();
      if (!mounted) {
        return;
      }
      if (bytes == null) {
        _notify('保存失败，请重试');
        return;
      }
      await AppScope.of(context).platformServices.saveImageToGallery(
        bytes,
        fileName: 'qrcode_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      _notify('已保存到相册');
    } on PlatformServiceException catch (error) {
      _notify(ErrorMessages.forPlatform(error));
    } catch (error) {
      _notify('保存失败：$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _share() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await _renderQrPng();
      if (bytes == null) {
        _notify('分享失败，请重试');
        return;
      }
      // The share sheet needs a real file, not in-memory bytes.
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}qrcode_share.png',
      );
      await file.writeAsBytes(bytes, flush: true);

      final box =
          _shareOriginKey.currentContext?.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      _notify('分享失败：$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('生成二维码')),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _input,
                    // Multiline, scrollable, so very long input cannot push the
                    // layout off screen (project spec §7.1).
                    minLines: 4,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      labelText: '要生成二维码的内容',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                      hintText: '支持文本、网址、中文与换行',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pasteFromClipboard,
                          icon: const Icon(Icons.content_paste),
                          label: const Text('粘贴'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _generate,
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text('生成'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _clear,
                          icon: const Icon(Icons.backspace_outlined),
                          label: const Text('清空'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_error != null)
                    _ErrorNotice(message: _error!)
                  else if (_generatedData == null)
                    const _EmptyResultHint()
                  else
                    _QrResult(
                      data: _generatedData!,
                      boundaryKey: _qrBoundaryKey,
                    ),
                ],
              ),
            ),
          ),
          if (_generatedData != null && _error == null)
            _ResultActions(
              busy: _busy,
              shareOriginKey: _shareOriginKey,
              onSave: _saveToGallery,
              onShare: _share,
            ),
        ],
      ),
    );
  }
}

class _QrResult extends StatelessWidget {
  const _QrResult({required this.data, required this.boundaryKey});

  final String data;
  final GlobalKey boundaryKey;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: RepaintBoundary(
        key: boundaryKey,
        child: Container(
          // Always white behind the code: a code rendered on a dark surface is
          // not reliably scannable, and the theme must not change that.
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: QrImageView(
            data: data,
            // `auto` picks the smallest version that fits; level M balances
            // tolerance against how much content can be encoded.
            version: QrVersions.auto,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            // Square, high enough resolution to stay crisp at export size.
            size: 260,
            gapless: true,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Colors.black,
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Colors.black,
            ),
            // Encoder limits are checked before rendering, but the widget is the
            // last line of defence against an unexpected overflow.
            errorStateBuilder: (context, error) => SizedBox(
              width: 260,
              height: 260,
              child: Center(
                child: Text(
                  '无法生成二维码，内容可能超出编码上限。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyResultHint extends StatelessWidget {
  const _EmptyResultHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(
          Icons.qr_code_2_outlined,
          size: 64,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text('生成后二维码会显示在这里', style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultActions extends StatelessWidget {
  const _ResultActions({
    required this.busy,
    required this.shareOriginKey,
    required this.onSave,
    required this.onShare,
  });

  final bool busy;
  final GlobalKey shareOriginKey;
  final Future<void> Function() onSave;
  final Future<void> Function() onShare;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          key: shareOriginKey,
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : onSave,
                icon: const Icon(Icons.download),
                label: const Text('保存到相册'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onShare,
                icon: const Icon(Icons.share),
                label: const Text('分享'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

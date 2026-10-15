import 'package:flutter/services.dart';

/// Clipboard access, behind an interface so the scan and generate flows can be
/// tested without a platform channel.
///
/// The clipboard is touched only when the user enabled automatic copying or
/// explicitly tapped copy/paste (project spec §11).
abstract interface class ClipboardService {
  Future<String?> readText();

  Future<void> writeText(String text);
}

class SystemClipboardService implements ClipboardService {
  const SystemClipboardService();

  @override
  Future<String?> readText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  @override
  Future<void> writeText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

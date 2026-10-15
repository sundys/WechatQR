import 'dart:ui' show Offset;

/// One payload decoded from a frame, with where it was found.
///
/// [center] is the centre of the QR code as a fraction of the camera preview —
/// `(0, 0)` top-left, `(1, 1)` bottom-right — so an indicator can be positioned
/// without the UI knowing anything about preview scaling or cropping.
///
/// It is `null` when the engine returned no vertices for that code, in which
/// case no indicator is shown for it. That is a real state on iOS today; see
/// docs/decisions/0006-ios-trollstore.md.
class ScannedCode {
  const ScannedCode({required this.text, this.center});

  /// The payload exactly as decoded.
  final String text;

  /// Centre of the code within the preview, or `null` when unknown.
  final Offset? center;

  @override
  String toString() =>
      'ScannedCode(${text.length} chars, center: ${center ?? 'unknown'})';
}

/// Which decoded payload to foreground when a frame (or image) contains more
/// than one QR code.
///
/// Policy: the **first non-blank entry in engine detection order** is primary.
/// That order is deterministic for a given input, which makes the selection
/// explainable rather than arbitrary. Every other decoded payload is reported
/// alongside it so multi-code input is never silently discarded (project spec
/// §6.1, §6.5) — the result sheet lists them all and the user can pick another
/// by closing and re-scanning.
class ScanResultSelection {
  const ScanResultSelection({required this.primary, required this.all});

  /// The payload shown first, exactly as decoded.
  final String primary;

  /// All usable payloads, in engine order, primary first.
  final List<String> all;

  bool get isMulti => all.length > 1;

  @override
  String toString() => 'ScanResultSelection(${all.length} result(s))';
}

abstract final class ScanResultPolicy {
  /// Selects a primary payload, or returns `null` when [texts] holds nothing
  /// usable (empty list, or only whitespace-only payloads).
  static ScanResultSelection? select(List<String> texts) {
    final usable = <String>[];
    for (final text in texts) {
      if (text.trim().isNotEmpty) {
        usable.add(text);
      }
    }
    if (usable.isEmpty) {
      return null;
    }
    return ScanResultSelection(
      primary: usable.first,
      all: List<String>.unmodifiable(usable),
    );
  }
}

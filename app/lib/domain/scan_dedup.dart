/// Short-window suppression of repeated identical scan results.
///
/// The engine re-detects the same code on every frame while it stays in view,
/// so without this a result sheet would reopen continuously and the history
/// would fill with duplicates (project spec §6.1, §6.2).
///
/// Time is passed in rather than read from the clock so the policy is
/// deterministic under test.
class ScanDedup {
  ScanDedup({this.window = const Duration(seconds: 3)});

  /// How long an identical payload stays suppressed after it was emitted.
  final Duration window;

  String? _lastContent;
  DateTime? _lastEmittedAt;

  /// Returns `true` if [content] should be surfaced to the user, recording the
  /// emission when it does.
  bool shouldEmit(String content, DateTime now) {
    final lastContent = _lastContent;
    final lastEmittedAt = _lastEmittedAt;
    if (lastContent == content &&
        lastEmittedAt != null &&
        now.difference(lastEmittedAt) < window) {
      return false;
    }
    _lastContent = content;
    _lastEmittedAt = now;
    return true;
  }

  /// Restarts the suppression window for [content] without emitting it.
  ///
  /// Used when the user closes a result sheet while the same code is still in
  /// frame, so the sheet does not immediately pop back up.
  void suppress(String content, DateTime now) {
    _lastContent = content;
    _lastEmittedAt = now;
  }

  /// Forgets the last result, e.g. when the user switches codes deliberately.
  void reset() {
    _lastContent = null;
    _lastEmittedAt = null;
  }
}

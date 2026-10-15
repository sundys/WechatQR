/// Where a decoded payload came from.
///
/// Recorded per history entry so the list can show a source hint. It is a
/// product-facing property only — nothing is uploaded anywhere.
enum ScanSource {
  camera,
  gallery;

  String get storageKey => name;

  static ScanSource fromStorageKey(Object? value) {
    for (final source in ScanSource.values) {
      if (source.storageKey == value) {
        return source;
      }
    }
    return ScanSource.camera;
  }
}

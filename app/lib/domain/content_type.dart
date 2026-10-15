/// Classification of a decoded QR payload.
///
/// Mirrors the `Text | Url | Other` model in the project spec. Classification
/// only ever *describes* content for display; it never makes content
/// executable. See [ContentClassifier] for the rules.
enum ContentType {
  /// Anything that is not a validated `http`/`https` URL, including empty
  /// payloads and text that merely looks like a URL.
  text,

  /// A payload that parsed as an absolute `http`/`https` URL with a host.
  url,

  /// A payload that is known not to be plain text but also not a URL — for
  /// example an unsupported or dangerous scheme such as `javascript:` or
  /// `file:`. Never opened automatically.
  other;

  String get storageKey => name;

  static ContentType fromStorageKey(Object? value) {
    for (final type in ContentType.values) {
      if (type.storageKey == value) {
        return type;
      }
    }
    return ContentType.text;
  }
}

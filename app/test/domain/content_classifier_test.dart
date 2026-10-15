import 'package:flutter_test/flutter_test.dart';
import 'package:wechatqr/domain/content_classifier.dart';
import 'package:wechatqr/domain/content_type.dart';

void main() {
  group('classify', () {
    test('recognises http and https URLs', () {
      expect(
        ContentClassifier.classify('https://example.com/a?b=1'),
        ContentType.url,
      );
      expect(ContentClassifier.classify('http://example.com'), ContentType.url);
      expect(
        ContentClassifier.classify('HTTPS://EXAMPLE.COM'),
        ContentType.url,
      );
    });

    test('treats ordinary text as text', () {
      expect(ContentClassifier.classify('你好，世界'), ContentType.text);
      expect(ContentClassifier.classify('just some words'), ContentType.text);
      expect(ContentClassifier.classify('example.com'), ContentType.text);
      expect(ContentClassifier.classify(''), ContentType.text);
      expect(ContentClassifier.classify('   '), ContentType.text);
    });

    test('treats malformed URLs as text, never as openable', () {
      expect(ContentClassifier.classify('http://'), ContentType.text);
      expect(ContentClassifier.classify('https://'), ContentType.text);
      expect(ContentClassifier.classify('http:/example.com'), ContentType.text);
    });

    test('flags non-http schemes as other', () {
      for (final payload in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'intent://scan/#Intent;scheme=zxing;end',
        'data:text/html;base64,PHNjcmlwdD4=',
        'content://com.example/secret',
        'mailto:someone@example.com',
      ]) {
        expect(
          ContentClassifier.classify(payload),
          ContentType.other,
          reason: payload,
        );
      }
    });
  });

  group('browserUri', () {
    test('returns the URL for openable http(s) payloads', () {
      expect(
        ContentClassifier.browserUri(' https://example.com/x ')?.host,
        'example.com',
      );
    });

    test('refuses every dangerous or unknown scheme', () {
      // The hard requirement: nothing but http(s) may ever be handed to the
      // platform browser.
      for (final payload in [
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        '  javascript:alert(1)',
        'file:///data/data/com.sundys.wechatqr/files/x',
        'intent://x/#Intent;end',
        'data:text/plain,hi',
        'content://media/external/images/1',
        'about:blank',
        'chrome://settings',
        'ftp://example.com/f',
      ]) {
        expect(ContentClassifier.browserUri(payload), isNull, reason: payload);
      }
    });

    test('refuses malformed http payloads', () {
      expect(ContentClassifier.browserUri('http://'), isNull);
      expect(ContentClassifier.browserUri('https://'), isNull);
      expect(ContentClassifier.browserUri(''), isNull);
      expect(ContentClassifier.browserUri('not a url'), isNull);
    });
  });

  group('displayHost', () {
    test('shows the parsed host, not the raw text', () {
      // A URL with embedded credentials must not be able to display
      // "trusted.example" while pointing somewhere else.
      expect(
        ContentClassifier.displayHost('https://user:pass@evil.example/login'),
        'evil.example',
      );
    });

    test('includes a non-default port and omits the default one', () {
      expect(
        ContentClassifier.displayHost('https://example.com:8443/x'),
        'example.com:8443',
      );
      expect(
        ContentClassifier.displayHost('https://example.com/x'),
        'example.com',
      );
    });

    test('returns null for anything not openable', () {
      expect(ContentClassifier.displayHost('javascript:alert(1)'), isNull);
      expect(ContentClassifier.displayHost('plain text'), isNull);
    });
  });
}

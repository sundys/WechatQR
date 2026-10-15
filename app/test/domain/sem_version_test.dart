import 'package:flutter_test/flutter_test.dart';
import 'package:wechatqr/domain/sem_version.dart';

void main() {
  group('SemVersion.tryParse', () {
    test('parses plain and dotted versions', () {
      final version = SemVersion.tryParse('1.2.3')!;
      expect(version.major, 1);
      expect(version.minor, 2);
      expect(version.patch, 3);
      expect(version.isPreRelease, isFalse);
    });

    test('accepts a leading version prefix', () {
      expect(SemVersion.tryParse('v1.2.3'), SemVersion.parse('1.2.3'));
      expect(SemVersion.tryParse('V2.0.0'), SemVersion.parse('2.0.0'));
      expect(SemVersion.tryParse('app-v1.2.3'), SemVersion.parse('1.2.3'));
    });

    test('treats missing minor and patch as zero', () {
      expect(SemVersion.tryParse('1'), SemVersion.parse('1.0.0'));
      expect(SemVersion.tryParse('1.2'), SemVersion.parse('1.2.0'));
    });

    test('separates pre-release identifiers and ignores build metadata', () {
      final version = SemVersion.tryParse('1.2.3-rc.1+build.5')!;
      expect(version.preRelease, ['rc', '1']);
      expect(version.isPreRelease, isTrue);
      expect(version.toString(), '1.2.3-rc.1');
      expect(SemVersion.tryParse('1.2.3+build.5'), SemVersion.parse('1.2.3'));
    });

    test('rejects things that are not versions', () {
      expect(SemVersion.tryParse(null), isNull);
      expect(SemVersion.tryParse(''), isNull);
      expect(SemVersion.tryParse('   '), isNull);
      expect(SemVersion.tryParse('latest'), isNull);
      // A four-part version is not semver and must not be silently truncated.
      expect(SemVersion.tryParse('1.2.3.4'), isNull);
      expect(SemVersion.tryParse('1.2.3-'), isNull);
    });

    test('parse throws where tryParse returns null', () {
      expect(() => SemVersion.parse('nope'), throwsFormatException);
    });
  });

  group('comparison', () {
    test('orders numerically, not lexically', () {
      // The whole reason this class exists: string sorting puts 1.9.0 above
      // 1.10.0.
      expect(
        SemVersion.parse('1.10.0').isNewerThan(SemVersion.parse('1.9.0')),
        isTrue,
      );
      expect(
        SemVersion.parse('2.0.0').isNewerThan(SemVersion.parse('10.0.0')),
        isFalse,
      );
    });

    test('compares each segment in order', () {
      expect(
        SemVersion.parse('1.2.10').isNewerThan(SemVersion.parse('1.2.9')),
        isTrue,
      );
      expect(
        SemVersion.parse('1.3.0').isNewerThan(SemVersion.parse('1.2.99')),
        isTrue,
      );
    });

    test('a release outranks its own pre-releases', () {
      expect(
        SemVersion.parse('1.0.0').isNewerThan(SemVersion.parse('1.0.0-rc.2')),
        isTrue,
      );
      expect(
        SemVersion.parse('1.0.0-rc.2').isNewerThan(SemVersion.parse('1.0.0')),
        isFalse,
      );
    });

    test('orders pre-release identifiers per the spec', () {
      const ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (var i = 0; i < ordered.length - 1; i++) {
        final lower = SemVersion.parse(ordered[i]);
        final higher = SemVersion.parse(ordered[i + 1]);
        expect(
          higher.isNewerThan(lower),
          isTrue,
          reason: '${ordered[i + 1]} should be newer than ${ordered[i]}',
        );
      }
    });

    test('numeric identifiers rank below alphanumeric ones', () {
      expect(
        SemVersion.parse(
          '1.0.0-alpha',
        ).isNewerThan(SemVersion.parse('1.0.0-1')),
        isTrue,
      );
    });

    test('equality follows precedence', () {
      expect(SemVersion.parse('v1.2.3'), SemVersion.parse('1.2.3'));
      expect(
        SemVersion.parse('1.2.3+build1').hashCode,
        SemVersion.parse('1.2.3+build2').hashCode,
      );
    });
  });
}

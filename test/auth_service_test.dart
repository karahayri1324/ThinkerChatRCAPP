import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_app/services/auth_service.dart';

String _jwtWithExp(dynamic exp) {
  String seg(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg({'sub': 'u', if (exp != null) 'exp': exp})}.sig';
}

void main() {
  group('normalizeServerUrl', () {
    test('adds https scheme when missing', () {
      expect(AuthService.normalizeServerUrl('my-relay.com'),
          'https://my-relay.com');
    });

    test('strips trailing slashes', () {
      expect(AuthService.normalizeServerUrl('https://my-relay.com///'),
          'https://my-relay.com');
    });

    test('keeps explicit http scheme and port', () {
      expect(AuthService.normalizeServerUrl('http://localhost:8080/'),
          'http://localhost:8080');
    });

    test('trims whitespace', () {
      expect(AuthService.normalizeServerUrl('  https://a.com  '),
          'https://a.com');
    });

    test('rejects empty input', () {
      expect(() => AuthService.normalizeServerUrl('   '),
          throwsFormatException);
    });

    test('rejects garbage without a host', () {
      expect(() => AuthService.normalizeServerUrl('http://'),
          throwsFormatException);
      expect(() => AuthService.normalizeServerUrl('https://'),
          throwsFormatException);
      expect(() => AuthService.normalizeServerUrl('/'), throwsFormatException);
    });

    test('preserves a path prefix', () {
      expect(AuthService.normalizeServerUrl('https://host.com/relay/'),
          'https://host.com/relay');
    });
  });

  group('buildWsUrl', () {
    test('https becomes wss', () {
      expect(AuthService.buildWsUrl('https://relay.com', 'tok'),
          'wss://relay.com/ws/client?token=tok');
    });

    test('http becomes ws and port is preserved', () {
      expect(AuthService.buildWsUrl('http://10.0.2.2:9000', 'tok'),
          'ws://10.0.2.2:9000/ws/client?token=tok');
    });

    test('path prefix is preserved (reverse-proxied relay)', () {
      expect(AuthService.buildWsUrl('https://host.com/relay', 'tok'),
          'wss://host.com/relay/ws/client?token=tok');
    });

    test('token is URL-encoded', () {
      expect(AuthService.buildWsUrl('https://a.com', 'a+b/c='),
          'wss://a.com/ws/client?token=a%2Bb%2Fc%3D');
    });

    test('null token yields empty token param', () {
      expect(AuthService.buildWsUrl('https://a.com', null),
          'wss://a.com/ws/client?token=');
    });
  });

  group('decodeJwtExpiry', () {
    test('decodes exp claim', () {
      final expiry = AuthService.decodeJwtExpiry(_jwtWithExp(1893456000));
      expect(expiry,
          DateTime.fromMillisecondsSinceEpoch(1893456000 * 1000));
    });

    test('returns null for JWT without exp', () {
      expect(AuthService.decodeJwtExpiry(_jwtWithExp(null)), isNull);
    });

    test('returns null for opaque tokens', () {
      expect(AuthService.decodeJwtExpiry('not-a-jwt'), isNull);
      expect(AuthService.decodeJwtExpiry('a.b'), isNull);
      expect(AuthService.decodeJwtExpiry('x.y!!.z'), isNull);
    });

    test('returns null when exp is not numeric', () {
      expect(AuthService.decodeJwtExpiry(_jwtWithExp('soon')), isNull);
    });
  });
}

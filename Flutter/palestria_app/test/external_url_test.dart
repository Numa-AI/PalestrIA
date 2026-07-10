import 'package:flutter_test/flutter_test.dart';
import 'package:palestria_app/core/security/external_url.dart';

void main() {
  group('trustedExternalUri', () {
    test('accetta HTTPS dei domini Stripe e applicativi', () {
      expect(
        trustedExternalUri('https://checkout.stripe.com/c/pay/test'),
        isNotNull,
      );
      expect(
        trustedExternalUri('https://app.palestria.app/join/studio'),
        isNotNull,
      );
      expect(
        trustedExternalUri('https://numa-ai.github.io/PalestrIA'),
        isNotNull,
      );
    });

    test('rifiuta schemi, host e credenziali non affidabili', () {
      expect(trustedExternalUri('javascript:alert(1)'), isNull);
      expect(trustedExternalUri('http://checkout.stripe.com/test'), isNull);
      expect(
        trustedExternalUri('https://stripe.com.evil.example/test'),
        isNull,
      );
      expect(trustedExternalUri('https://user:pass@stripe.com/test'), isNull);
      expect(trustedExternalUri(null), isNull);
    });
  });
}

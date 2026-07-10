import '../config.dart';

/// Valida gli URL sensibili ricevuti dal backend prima di passarli al sistema.
/// Gli URL di Stripe possono usare sottodomini diversi; gli altri redirect
/// devono restare sui domini applicativi esplicitamente noti.
Uri? trustedExternalUri(String? raw) {
  if (raw == null) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }

  final host = uri.host.toLowerCase();
  final appHost = Uri.parse(AppConfig.webBaseUrl).host.toLowerCase();
  final trusted =
      host == appHost ||
      host == 'app.palestria.app' ||
      host == 'stripe.com' ||
      host.endsWith('.stripe.com');
  return trusted ? uri : null;
}

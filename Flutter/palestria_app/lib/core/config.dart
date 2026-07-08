/// Config Supabase — valori PUBBLICI (protetti da RLS lato DB),
/// identici a quelli di js/supabase-client.js della web app.
class AppConfig {
  AppConfig._();

  static const supabaseUrl = 'https://rwaiekhllujximrqftmp.supabase.co';
  static const supabaseAnonKey = 'sb_publishable_SDlyqyh2C78ZlQ42hQJClA_e1LIp2x5';

  /// Pagina web per i pagamenti Stripe e il tablet QR (restano fuori dall'app
  /// per evitare i vincoli di in-app purchase del Play Store).
  /// Deve combaciare con il deploy GitHub Pages e con `SITE_URL` delle edge
  /// function (vedi supabase/functions/stripe-connect/index.ts).
  /// ⚠️ Cambierà quando si passerà al dominio proprietario: aggiornare qui + SITE_URL.
  static const webBaseUrl = 'https://renumaa.github.io/PalestrIA';
}

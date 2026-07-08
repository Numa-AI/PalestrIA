import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_providers.dart';
import 'normalize.dart';

/// Esito di login/signup, con messaggi d'errore già in italiano (come il web).
class AuthResult {
  const AuthResult.ok() : ok = true, error = null;
  const AuthResult.fail(this.error) : ok = false;

  final bool ok;
  final String? error;
}

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  /// Login email/password (messaggi mappati come loginWithPassword del web).
  Future<AuthResult> loginWithPassword(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: email.trim(), password: password);
      return const AuthResult.ok();
    } on AuthException catch (e) {
      return AuthResult.fail(_mapAuthError(e));
    } catch (_) {
      return const AuthResult.fail(
          'Errore di connessione. Riprova tra qualche istante.');
    }
  }

  /// Signup CLIENTE nel contesto di una org (slug obbligatorio, come il web:
  /// senza slug il trigger handle_new_user non crea il profilo).
  Future<AuthResult> registerClient({
    required String name,
    required String email,
    required String password,
    required String orgSlug,
    String? whatsapp,
    String? codiceFiscale,
    String? indirizzoVia,
    String? indirizzoPaese,
    String? indirizzoCap,
  }) async {
    final slug = orgSlug.trim().toLowerCase();
    if (slug.isEmpty) {
      return const AuthResult.fail(
          'Studio non identificato: inserisci il codice della tua palestra.');
    }

    final phone =
        (whatsapp == null || whatsapp.trim().isEmpty) ? null : normalizePhone(whatsapp);
    try {
      if (phone != null) {
        final taken = await _client
            .rpc('is_whatsapp_taken', params: {'phone': phone});
        if (taken == true) {
          return const AuthResult.fail(
              'Questo numero WhatsApp è già registrato.');
        }
      }

      final res = await _auth.signUp(
        email: email.trim(),
        password: password,
        data: {
          'signup_type': 'client',
          'org_slug': slug,
          'full_name': capitalizeName(name),
          'whatsapp': ?phone,
          if (codiceFiscale != null && codiceFiscale.trim().isNotEmpty)
            'codice_fiscale': codiceFiscale.trim().toUpperCase(),
          if (indirizzoVia != null && indirizzoVia.trim().isNotEmpty)
            'indirizzo_via': indirizzoVia.trim(),
          if (indirizzoPaese != null && indirizzoPaese.trim().isNotEmpty)
            'indirizzo_paese': normalizeComune(indirizzoPaese),
          if (indirizzoCap != null && indirizzoCap.trim().isNotEmpty)
            'indirizzo_cap': indirizzoCap.trim(),
        },
      );

      // Safety-net del web: se la sessione è già attiva (conferma email OFF),
      // join idempotente alla org.
      if (res.session != null) {
        try {
          await _client
              .rpc('join_organization', params: {'p_org_slug': slug});
        } catch (_) {
          // idempotente/fail-silent come nel web
        }
      }
      return const AuthResult.ok();
    } on AuthException catch (e) {
      return AuthResult.fail(_mapAuthError(e));
    } catch (_) {
      return const AuthResult.fail(
          'Errore di connessione. Riprova tra qualche istante.');
    }
  }

  Future<AuthResult> resetPassword(String email) async {
    try {
      await _auth.resetPasswordForEmail(email.trim());
      return const AuthResult.ok();
    } on AuthException catch (e) {
      return AuthResult.fail(_mapAuthError(e));
    }
  }

  Future<AuthResult> updatePassword(String newPassword) async {
    try {
      await _auth.updateUser(UserAttributes(password: newPassword));
      return const AuthResult.ok();
    } on AuthException catch (e) {
      return AuthResult.fail(_mapAuthError(e));
    }
  }

  /// Logout con teardown per-tenant (equivalente di logoutUser del web §2.8):
  /// rimuove le cache locali namespaced `org_<id>_*` e gli snapshot.
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    final orgKeys = prefs
        .getKeys()
        .where((k) =>
            k.startsWith('org_') ||
            k.startsWith('cache_') ||
            k == 'branding_snapshot')
        .toList();
    for (final k in orgKeys) {
      await prefs.remove(k);
    }
    try {
      await _auth
          .signOut(scope: SignOutScope.local)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // come nel web: se Supabase non risponde si procede comunque
    }
  }

  String _mapAuthError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('invalid login credentials')) {
      return 'Email o password errata.';
    }
    if (msg.contains('already registered') || msg.contains('already exists')) {
      return 'Email già registrata.';
    }
    if (msg.contains('email not confirmed')) {
      return 'Email non confermata: controlla la tua casella di posta.';
    }
    if (msg.contains('password') && msg.contains('at least')) {
      return 'La password deve avere almeno 6 caratteri.';
    }
    if (msg.contains('rate limit') || msg.contains('too many')) {
      return 'Troppi tentativi. Attendi qualche minuto e riprova.';
    }
    return 'Errore: ${e.message}';
  }
}

final authRepositoryProvider =
    Provider<AuthRepository>((ref) => AuthRepository(ref.watch(supabaseProvider)));

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_providers.dart';
import 'normalize.dart';

/// Esito di login/signup, con messaggi d'errore già in italiano (come il web).
class AuthResult {
  const AuthResult.ok() : ok = true, error = null, pendingEmail = false;
  const AuthResult.fail(this.error) : ok = false, pendingEmail = false;

  /// Signup trainer con conferma email attiva: NON è un errore, è un invito a
  /// confermare l'email; lo studio verrà creato al primo login.
  const AuthResult.emailPending(this.error) : ok = false, pendingEmail = true;

  final bool ok;
  final String? error;
  final bool pendingEmail;
}

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  /// Login email/password (messaggi mappati come loginWithPassword del web).
  Future<AuthResult> loginWithPassword(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: email.trim(), password: password);
      // Completa uno studio in attesa (signup trainer con conferma email ON):
      // no-op (una lettura di prefs) per i clienti normali.
      await finalizePendingStudio();
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

  /// Slug dello studio dal nome (equivalente di slugify di signup-trainer.html):
  /// minuscolo, accenti rimossi, non-alfanumerici → '-', trim '-', max 40 char.
  String studioSlug(String name) {
    final folded = _foldAccents(name.toLowerCase().trim());
    final base = folded
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return base.length > 40 ? base.substring(0, 40) : base;
  }

  String _foldAccents(String s) {
    const map = {
      'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a',
      'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
      'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
      'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
      'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
      'ç': 'c', 'ñ': 'n',
    };
    final sb = StringBuffer();
    for (final ch in s.split('')) {
      sb.write(map[ch] ?? ch);
    }
    return sb.toString();
  }

  /// Signup TRAINER self-serve: crea l'account (signup_type='trainer', niente
  /// profilo cliente) e la sua organizzazione con trial 30gg (RPC
  /// create_organization). Port di signup-trainer.html.
  Future<AuthResult> registerTrainer({
    required String studioName,
    required String trainerName,
    required String email,
    required String password,
  }) async {
    final name = studioName.trim();
    final slug = studioSlug(name);
    if (slug.length < 3) {
      return const AuthResult.fail('Il nome dello studio è troppo corto.');
    }
    final mail = email.trim().toLowerCase();

    try {
      // 1) registra l'utente come trainer.
      var hasSession = false;
      try {
        final res = await _auth.signUp(
          email: mail,
          password: password,
          data: {
            'full_name': capitalizeName(trainerName),
            'signup_type': 'trainer',
          },
        );
        hasSession = res.session != null;
      } on AuthException catch (e) {
        final m = e.message.toLowerCase();
        if (!(m.contains('already registered') ||
            m.contains('already exists'))) {
          rethrow;
        }
        // utente già esistente: si prosegue col login e si crea lo studio.
      }

      // 2) assicura una sessione (signUp non logga con conferma email ON o
      //    utente già esistente).
      if (!hasSession) {
        try {
          final signIn =
              await _auth.signInWithPassword(email: mail, password: password);
          hasSession = signIn.session != null;
        } on AuthException catch (e) {
          if (e.message.toLowerCase().contains('invalid login credentials')) {
            return const AuthResult.fail(
                'Esiste già un account con questa email (password diversa). Accedi dal login.');
          }
          // conferma email richiesta: memorizza lo studio, si crea al login.
          await _savePendingStudio(name, slug);
          return const AuthResult.emailPending(
              'Ti abbiamo inviato una email di conferma. Confermala, poi accedi per completare la creazione dello studio.');
        }
      }
      if (!hasSession) {
        await _savePendingStudio(name, slug);
        return const AuthResult.emailPending(
            'Conferma la tua email, poi accedi per completare la creazione dello studio.');
      }

      // 3) crea l'organizzazione (owner + settings + trial 30gg).
      final org = await _createOrganization(name, slug);
      if (!org.ok) return org;

      // 4) refresh per ottenere il claim org_id nel JWT.
      try {
        await _auth.refreshSession();
      } catch (_) {}
      await _clearPendingStudio();
      return const AuthResult.ok();
    } on AuthException catch (e) {
      return AuthResult.fail(_mapAuthError(e));
    } catch (_) {
      return const AuthResult.fail(
          'Errore di connessione. Riprova tra qualche istante.');
    }
  }

  Future<AuthResult> _createOrganization(String name, String slug) async {
    try {
      await _client
          .rpc('create_organization', params: {'p_name': name, 'p_slug': slug});
      return const AuthResult.ok();
    } on PostgrestException catch (e) {
      final m = e.message.toLowerCase();
      if (m.contains('slug_taken')) {
        return const AuthResult.fail(
            'Questo nome studio è già in uso. Provane un altro.');
      }
      if (m.contains('invalid_slug')) {
        return const AuthResult.fail(
            'Nome studio non valido: usa lettere e numeri.');
      }
      return AuthResult.fail(
          'Errore nella creazione dello studio: ${e.message}');
    }
  }

  static const _pendingStudioKey = 'pending_studio';

  Future<void> _savePendingStudio(String name, String slug) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _pendingStudioKey, jsonEncode({'name': name, 'slug': slug}));
  }

  Future<void> _clearPendingStudio() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingStudioKey);
  }

  /// Dopo un login riuscito: se c'era uno studio in attesa (signup trainer con
  /// conferma email ON) e l'utente non ha ancora una org, completa la creazione.
  Future<void> finalizePendingStudio() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingStudioKey);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final name = (data['name'] as String?)?.trim() ?? '';
      final slug = (data['slug'] as String?)?.trim() ?? '';
      if (slug.isEmpty) {
        await prefs.remove(_pendingStudioKey);
        return;
      }
      final uid = _auth.currentUser?.id;
      if (uid == null) return; // ritenta al prossimo login
      final existing = await _client
          .from('org_members')
          .select('org_id')
          .eq('user_id', uid)
          .eq('status', 'active')
          .limit(1);
      if (existing.isEmpty) {
        await _client.rpc('create_organization',
            params: {'p_name': name, 'p_slug': slug});
        try {
          await _auth.refreshSession();
        } catch (_) {}
      }
      await prefs.remove(_pendingStudioKey); // creato o già membro
    } catch (_) {
      // best-effort: lascia il pending per un nuovo tentativo al prossimo login.
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

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import '../theme/org_theme.dart';

/// Port del modulo `OrgSettings` web (js/org-settings.js, spec-data §6).
/// Cache: memoria → SharedPreferences `org_<id>_<key>` → default.
/// Scritture via RPC `upsert_org_setting`; aggiornamenti live via Realtime
/// (canale `org_settings_<orgId>`).
class OrgSettingsService {
  OrgSettingsService(this._client, this.orgId, this._prefs);

  final SupabaseClient _client;
  final String orgId;
  final SharedPreferences _prefs;

  final Map<String, dynamic> _cache = {};
  RealtimeChannel? _channel;
  final List<void Function(String key, dynamic value)> _listeners = [];

  String _prefsKey(String key) => 'org_${orgId}_$key';

  Future<void> load() async {
    final rows =
        await _client.from('org_settings').select('key, value').eq('org_id', orgId);
    for (final row in rows) {
      final key = row['key'] as String;
      final value = row['value'];
      _cache[key] = value;
      await _prefs.setString(_prefsKey(key), jsonEncode(value));
    }
  }

  dynamic get(String key, [dynamic defaultValue]) {
    if (_cache.containsKey(key)) return _cache[key] ?? defaultValue;
    final raw = _prefs.getString(_prefsKey(key));
    if (raw != null) {
      try {
        final v = jsonDecode(raw);
        _cache[key] = v;
        return v ?? defaultValue;
      } catch (_) {}
    }
    return defaultValue;
  }

  bool getBool(String key, bool defaultValue) {
    final v = get(key);
    return v is bool ? v : defaultValue;
  }

  num getNumber(String key, num defaultValue) {
    final v = get(key);
    return v is num ? v : defaultValue;
  }

  String getString(String key, String defaultValue) {
    final v = get(key);
    return v is String && v.isNotEmpty ? v : defaultValue;
  }

  Future<void> set(String key, dynamic value) async {
    await _client.rpc('upsert_org_setting',
        params: {'p_key': key, 'p_value': value});
    _cache[key] = value;
    await _prefs.setString(_prefsKey(key), jsonEncode(value));
    _notify(key, value);
  }

  /// Realtime: aggiorna cache+prefs e notifica i listener a ogni modifica.
  void subscribe() {
    if (_channel != null) return;
    _channel = _client
        .channel('org_settings_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'org_settings',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'org_id',
            value: orgId,
          ),
          callback: (payload) {
            final record = payload.eventType == PostgresChangeEvent.delete
                ? payload.oldRecord
                : payload.newRecord;
            final key = record['key'] as String?;
            if (key == null) return;
            final value = payload.eventType == PostgresChangeEvent.delete
                ? null
                : payload.newRecord['value'];
            _cache[key] = value;
            if (value == null) {
              _prefs.remove(_prefsKey(key));
            } else {
              _prefs.setString(_prefsKey(key), jsonEncode(value));
            }
            _notify(key, value);
          },
        )
        .subscribe();
  }

  void addListener(void Function(String key, dynamic value) listener) =>
      _listeners.add(listener);

  void _notify(String key, dynamic value) {
    for (final l in List.of(_listeners)) {
      l(key, value);
    }
  }

  /// Chiude il canale Realtime e i listener (rebuild del provider).
  /// NON tocca la cache persistita: quella si svuota solo al logout.
  Future<void> dispose() async {
    _listeners.clear();
    if (_channel != null) {
      await _client.removeChannel(_channel!);
      _channel = null;
    }
  }

  /// Teardown al logout: svuota cache, rimuove le chiavi `org_<id>_*`,
  /// chiude il canale Realtime (come OrgSettings.reset() web).
  Future<void> reset() async {
    _cache.clear();
    final prefix = 'org_${orgId}_';
    for (final k in _prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      await _prefs.remove(k);
    }
    await dispose();
  }

  /// Costruisce l'OrgBranding corrente dalle chiavi `branding.*`.
  OrgBranding currentBranding() => OrgBranding(
        primary: OrgBranding.parseHex(
                get('branding.primary_color') as String?) ??
            const OrgBranding().primary,
        logoUrl: get('branding.logo_url') as String?,
        studioName: get('branding.studio_name') as String?,
      );
}

/// Servizio OrgSettings caricato per la org corrente. Applica il branding al
/// tema e resta in ascolto Realtime (le chiavi `branding.*` ri-applicano il
/// tema live, come nel web).
final orgSettingsProvider = FutureProvider<OrgSettingsService?>((ref) async {
  final orgContext = await ref.watch(orgContextProvider.future);
  final orgId = orgContext.orgId;
  if (orgId == null) return null;

  final prefs = await SharedPreferences.getInstance();
  final service =
      OrgSettingsService(ref.watch(supabaseProvider), orgId, prefs);
  await service.load();
  service.subscribe();

  final brandingNotifier = ref.read(orgBrandingProvider.notifier);
  await brandingNotifier.apply(service.currentBranding());
  service.addListener((key, _) {
    if (key.startsWith('branding.')) {
      brandingNotifier.apply(service.currentBranding());
    }
  });

  ref.onDispose(() => service.dispose());
  return service;
});

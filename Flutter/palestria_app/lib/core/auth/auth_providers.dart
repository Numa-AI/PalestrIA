import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_profile.dart';

final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

/// Stream degli eventi auth (INITIAL_SESSION, SIGNED_IN, TOKEN_REFRESHED, ...).
final authChangesProvider = StreamProvider<AuthState>(
  (ref) => ref.watch(supabaseProvider).auth.onAuthStateChange,
);

/// Sessione corrente (null = non autenticato).
final sessionProvider = Provider<Session?>((ref) {
  final change = ref.watch(authChangesProvider);
  return change.asData?.value.session ??
      ref.watch(supabaseProvider).auth.currentSession;
});

/// Contesto org dell'utente, dai claim JWT `app_metadata.org_id`/`org_role`
/// iniettati dal Custom Access Token Hook. Il fallback (query org_members /
/// profiles) copre il caso di hook non registrato, come nel web.
class OrgContext {
  const OrgContext({this.orgId, this.orgRole});

  final String? orgId;

  /// owner | admin | staff — i clienti finali NON hanno org_role.
  final String? orgRole;

  bool get isOrgAdmin => orgRole == 'owner' || orgRole == 'admin';
  bool get isStaffMember => orgRole != null;
  bool get hasOrg => orgId != null;
}

final orgContextProvider = FutureProvider<OrgContext>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const OrgContext();

  final meta = session.user.appMetadata;
  final claimOrgId = meta['org_id'] as String?;
  final claimOrgRole = meta['org_role'] as String?;
  if (claimOrgId != null) {
    return OrgContext(orgId: claimOrgId, orgRole: claimOrgRole);
  }

  // Fallback lento (hook non registrato o claim non ancora refreshato):
  // membership attiva più vecchia, poi profiles.org_id.
  final client = ref.read(supabaseProvider);
  final memberships = await client
      .from('org_members')
      .select('org_id, role')
      .eq('user_id', session.user.id)
      .eq('status', 'active')
      .order('created_at', ascending: true)
      .limit(1);
  if (memberships.isNotEmpty) {
    return OrgContext(
      orgId: memberships.first['org_id'] as String?,
      orgRole: memberships.first['role'] as String?,
    );
  }

  final profile = await client
      .from('profiles')
      .select('org_id')
      .eq('id', session.user.id)
      .maybeSingle();
  return OrgContext(orgId: profile?['org_id'] as String?);
});

/// Profilo cliente (`profiles`). Null per owner/staff senza riga profiles.
final userProfileProvider = FutureProvider<UserProfile?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return null;
  final client = ref.read(supabaseProvider);
  final row = await client
      .from('profiles')
      .select(UserProfile.selectColumns)
      .eq('id', session.user.id)
      .maybeSingle();
  return row == null ? null : UserProfile.fromRow(row);
});

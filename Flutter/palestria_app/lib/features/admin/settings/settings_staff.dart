import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';

/// Sezione "Staff / Membri" (port di _settRenderStaff §7, adminOnly): invita un
/// membro (`invite_org_member`), lista `org_members` con nome/email dai profili,
/// cambia ruolo (staff/admin) e revoca. L'owner non è modificabile.
class StaffSection extends ConsumerStatefulWidget {
  const StaffSection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  ConsumerState<StaffSection> createState() => _StaffSectionState();
}

class _Member {
  _Member(this.id, this.userId, this.role, this.status, this.invitedEmail,
      this.name, this.email);
  final String id;
  final String? userId;
  final String role;
  final String status;
  final String? invitedEmail;
  final String? name;
  final String? email;
}

class _StaffSectionState extends ConsumerState<StaffSection> {
  final _inviteEmail = TextEditingController();
  String _inviteRole = 'staff';
  bool _inviting = false;
  late Future<List<_Member>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _inviteEmail.dispose();
    super.dispose();
  }

  String get _orgId => widget.service.orgId;

  Future<List<_Member>> _load() async {
    final client = ref.read(supabaseProvider);
    final rows = await client
        .from('org_members')
        .select('id,user_id,role,status,invited_email')
        .eq('org_id', _orgId)
        .order('role');
    final members = [for (final r in rows) (r as Map).cast<String, dynamic>()];
    final userIds =
        members.map((m) => m['user_id'] as String?).whereType<String>().toList();
    final profMap = <String, Map<String, dynamic>>{};
    if (userIds.isNotEmpty) {
      final profs = await client
          .from('profiles')
          .select('id,name,email')
          .inFilter('id', userIds);
      for (final p in profs) {
        final m = (p as Map).cast<String, dynamic>();
        profMap[m['id'] as String] = m;
      }
    }
    return [
      for (final m in members)
        _Member(
          m['id'] as String,
          m['user_id'] as String?,
          (m['role'] as String?) ?? 'staff',
          (m['status'] as String?) ?? 'active',
          m['invited_email'] as String?,
          profMap[m['user_id']]?['name'] as String?,
          profMap[m['user_id']]?['email'] as String?,
        )
    ];
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _invite() async {
    final email = _inviteEmail.text.trim().toLowerCase();
    final messenger = ScaffoldMessenger.of(context);
    if (!email.contains('@')) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Inserisci un\'email valida.')));
      return;
    }
    setState(() => _inviting = true);
    try {
      await ref.read(supabaseProvider).rpc('invite_org_member',
          params: {'p_email': email, 'p_role': _inviteRole});
      _inviteEmail.clear();
      messenger.showSnackBar(const SnackBar(content: Text('Invito inviato.')));
      _reload();
    } catch (e) {
      final msg = e.toString().contains('invalid_role')
          ? 'Ruolo non valido'
          : e.toString().contains('unauthorized')
              ? 'Permesso negato'
              : 'L\'utente deve essere registrato per essere invitato.';
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Future<void> _changeRole(_Member m, String role) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(supabaseProvider)
          .from('org_members')
          .update({'role': role})
          .eq('id', m.id)
          .eq('org_id', _orgId)
          .neq('role', 'owner');
      messenger.showSnackBar(const SnackBar(content: Text('Ruolo aggiornato.')));
      _reload();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
      _reload();
    }
  }

  Future<void> _revoke(_Member m) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoca membro'),
        content: const Text('Revocare l\'accesso a questo membro?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Revoca')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(supabaseProvider)
          .from('org_members')
          .update({'status': 'revoked'})
          .eq('id', m.id)
          .eq('org_id', _orgId)
          .neq('role', 'owner');
      messenger.showSnackBar(const SnackBar(content: Text('Membro revocato.')));
      _reload();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    }
  }

  static const _roleLabels = {
    'owner': 'Proprietario',
    'admin': 'Admin',
    'staff': 'Staff'
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
            'Invita un utente registrato e assegna un ruolo, poi gestisci i '
            'membri della tua organizzazione.',
            style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _inviteEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
              labelText: 'Email', hintText: 'nome@esempio.it'),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _inviteRole,
                decoration: const InputDecoration(labelText: 'Ruolo'),
                items: const [
                  DropdownMenuItem(value: 'staff', child: Text('Staff')),
                  DropdownMenuItem(value: 'admin', child: Text('Admin')),
                ],
                onChanged: (v) => setState(() => _inviteRole = v ?? 'staff'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              onPressed: _inviting ? null : _invite,
              child: Text(_inviting ? '...' : 'Invita'),
            ),
          ],
        ),
        const Divider(height: AppSpacing.lg),
        const Text('Membri dello staff',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.subtle)),
        const SizedBox(height: AppSpacing.sm),
        FutureBuilder<List<_Member>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return const Text('Errore nel caricamento dei membri.',
                  style: AppText.meta);
            }
            final members = snap.data ?? const [];
            if (members.isEmpty) {
              return const Text('Nessun membro oltre al proprietario.',
                  style: AppText.meta);
            }
            return Column(children: [for (final m in members) _memberRow(m)]);
          },
        ),
      ],
    );
  }

  Widget _memberRow(_Member m) {
    final displayName = m.name ?? m.invitedEmail ?? m.email ?? '—';
    final displayEmail = m.email ?? m.invitedEmail ?? '';
    final isOwner = m.role == 'owner';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 6),
                    _badge(_roleLabels[m.role] ?? m.role,
                        isOwner ? const Color(0xFF8B5CF6) : AppColors.muted),
                    if (m.status != 'active') ...[
                      const SizedBox(width: 4),
                      _badge(m.status == 'invited' ? 'invitato' : 'revocato',
                          const Color(0xFF9CA3AF)),
                    ],
                  ],
                ),
                if (displayEmail.isNotEmpty)
                  Text(displayEmail, style: AppText.meta),
              ],
            ),
          ),
          if (!isOwner) ...[
            DropdownButton<String>(
              value: m.role == 'admin' ? 'admin' : 'staff',
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 'staff', child: Text('Staff')),
                DropdownMenuItem(value: 'admin', child: Text('Admin')),
              ],
              onChanged: (v) {
                if (v != null && v != m.role) _changeRole(m, v);
              },
            ),
            IconButton(
              icon: const Icon(Icons.person_remove, size: 20, color: Color(0xFFDC2626)),
              tooltip: 'Revoca',
              onPressed: () => _revoke(m),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: color)),
      );
}

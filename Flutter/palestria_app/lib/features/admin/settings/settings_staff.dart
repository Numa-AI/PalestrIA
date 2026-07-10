import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

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
    if (!email.contains('@')) {
      AppSnack.error(context, 'Inserisci un\'email valida.');
      return;
    }
    setState(() => _inviting = true);
    try {
      await ref.read(supabaseProvider).rpc('invite_org_member',
          params: {'p_email': email, 'p_role': _inviteRole});
      _inviteEmail.clear();
      if (mounted) AppSnack.success(context, 'Invito inviato.');
      _reload();
    } catch (e) {
      final msg = e.toString().contains('invalid_role')
          ? 'Ruolo non valido'
          : e.toString().contains('unauthorized')
              ? 'Permesso negato'
              : 'L\'utente deve essere registrato per essere invitato.';
      if (mounted) AppSnack.error(context, msg);
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Future<void> _changeRole(_Member m, String role) async {
    try {
      await ref
          .read(supabaseProvider)
          .from('org_members')
          .update({'role': role})
          .eq('id', m.id)
          .eq('org_id', _orgId)
          .neq('role', 'owner');
      if (mounted) AppSnack.success(context, 'Ruolo aggiornato.');
      _reload();
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore: $e');
      _reload();
    }
  }

  Future<void> _revoke(_Member m) async {
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
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.dangerDark),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Revoca')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(supabaseProvider)
          .from('org_members')
          .update({'status': 'revoked'})
          .eq('id', m.id)
          .eq('org_id', _orgId)
          .neq('role', 'owner');
      if (mounted) AppSnack.success(context, 'Membro revocato.');
      _reload();
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore: $e');
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
                child: AppLoading(),
              );
            }
            if (snap.hasError) {
              return AppErrorRetry(
                message: 'Errore nel caricamento dei membri.',
                onRetry: _reload,
              );
            }
            final members = snap.data ?? const [];
            if (members.isEmpty) {
              return const AppEmptyState(
                title: 'Nessun membro oltre al proprietario.',
                icon: Icons.group_outlined,
                compact: true,
              );
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
    final primary = Theme.of(context).colorScheme.primary;
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
                    StatusPill(
                      label: _roleLabels[m.role] ?? m.role,
                      background: (isOwner ? primary : AppColors.muted)
                          .withValues(alpha: 0.12),
                      foreground: isOwner ? primary : AppColors.muted,
                      dense: true,
                    ),
                    if (m.status != 'active') ...[
                      const SizedBox(width: 4),
                      StatusPill(
                        label: m.status == 'invited' ? 'invitato' : 'revocato',
                        background: AppColors.subtle.withValues(alpha: 0.12),
                        foreground: AppColors.subtle,
                        dense: true,
                      ),
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
              icon: const Icon(Icons.person_remove,
                  size: 20, color: AppColors.dangerDark),
              tooltip: 'Revoca',
              onPressed: () => _revoke(m),
            ),
          ],
        ],
      ),
    );
  }
}

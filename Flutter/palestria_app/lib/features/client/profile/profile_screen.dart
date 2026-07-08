import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/normalize.dart';
import '../../../core/models/user_profile.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../shared/area_switch.dart';
import 'billing_status.dart';
import 'edit_profile_sheet.dart';
import 'weekly_chart_sheet.dart';

/// Profilo cliente (port di prenotazioni.html §7.1-7.3): hero gradiente
/// scuro→viola, warning cert/anagrafica, card stato pagamenti.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(userProfileProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profilo'),
        actions: const [AdminAreaButton()],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore di caricamento: $e')),
        data: (p) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(userProfileProvider);
            ref.invalidate(clientBillingStatusProvider);
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (p != null) ...[
                _hero(context, ref, p),
                const SizedBox(height: AppSpacing.md),
                ..._warnings(context, ref, p),
                _billingCard(ref),
                const SizedBox(height: AppSpacing.md),
                _infoCard(p),
                const SizedBox(height: AppSpacing.md),
                OutlinedButton.icon(
                  onPressed: () => showWeeklyChart(context),
                  icon: const Icon(Icons.bar_chart, size: 18),
                  label: const Text('I miei allenamenti'),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              FilledButton.tonal(
                onPressed: () async {
                  await ref.read(authRepositoryProvider).logout();
                  await ref.read(orgBrandingProvider.notifier).reset();
                  if (context.mounted) context.go('/login');
                },
                child: const Text('Esci'),
              ),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          ),
        ),
      ),
    );
  }

  /// Hero profilo (§7.1): gradiente #1a1a1a → #2a1f3d → #6D28D9.
  Widget _hero(BuildContext context, WidgetRef ref, UserProfile p) {
    final firstName = p.name.split(' ').first;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1A1A), Color(0xFF2A1F3D), Color(0xFF6D28D9)],
          stops: [0, 0.5, 1],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
              color: Color(0x406D28D9),
              blurRadius: 20,
              offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFA78BFA), Color(0xFF8B5CF6), Color(0xFF6D28D9)],
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              firstName.isEmpty ? '?' : firstName[0].toUpperCase(),
              style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              firstName,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            onPressed: () => showEditProfileSheet(context, ref, p),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0x1FFFFFFF),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.edit, size: 16, color: Colors.white),
            tooltip: 'Modifica profilo',
          ),
        ],
      ),
    );
  }

  /// Warning anagrafica/certificato (§7.2), possono cumularsi.
  List<Widget> _warnings(BuildContext context, WidgetRef ref, UserProfile p) {
    final warnings = <Widget>[];

    Widget banner(String text, {required bool expired, VoidCallback? onTap}) =>
        GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: 11),
            decoration: BoxDecoration(
              color: expired ? const Color(0xFFFEF2F2) : const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(
                  color: expired
                      ? const Color(0xFFDC2626)
                      : const Color(0xFFF59E0B),
                  width: 4,
                ),
              ),
            ),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: expired
                    ? const Color(0xFFDC2626)
                    : const Color(0xFF92400E),
              ),
            ),
          ),
        );

    final anagraficaOk = isAnagraficaComplete(
      whatsapp: p.whatsapp,
      codiceFiscale: p.codiceFiscale,
      indirizzoVia: p.indirizzoVia,
      indirizzoPaese: p.indirizzoPaese,
      indirizzoCap: p.indirizzoCap,
    );
    if (!anagraficaOk) {
      warnings.add(banner('📋 Completa anagrafica',
          expired: false,
          onTap: () => showEditProfileSheet(context, ref, p)));
    }
    if (p.medicalCertExpiry == null) {
      warnings.add(banner('📋 Imposta Cert. Medico',
          expired: false,
          onTap: () => showEditProfileSheet(context, ref, p)));
    } else {
      final days =
          p.medicalCertExpiry!.difference(DateTime.now()).inDays;
      if (days < 0) {
        warnings.add(banner('⚠️ Certificato medico scaduto', expired: true));
      } else if (days <= 30) {
        warnings.add(banner(
            '⏳ Cert. medico scade fra $days giorn${days == 1 ? 'o' : 'i'}',
            expired: false));
      }
    }
    return warnings;
  }

  /// Card stato pagamenti (§7.3).
  Widget _billingCard(WidgetRef ref) {
    final statusAsync = ref.watch(clientBillingStatusProvider);
    final status = statusAsync.value;
    if (status == null) return const SizedBox.shrink();

    final (border, bg) = switch (status.tone) {
      'ok' => (const Color(0xFF22C55E), const Color(0xFFF0FDF4)),
      'warn' => (const Color(0xFFF59E0B), const Color(0xFFFFFBEB)),
      _ => (AppColors.border, Colors.white),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: 1.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Text(status.icon, style: const TextStyle(fontSize: 25)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Color(0xFF1A1A1A))),
                Text(status.detail,
                    style: const TextStyle(
                        fontSize: 13.5, color: Color(0xFF64748B))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(UserProfile p) {
    Widget row(IconData icon, String? value) => value == null || value.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(icon, size: 18, color: AppColors.muted),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                    child: Text(value, style: const TextStyle(fontSize: 14.5))),
              ],
            ),
          );

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row(Icons.person_outline, p.name),
          row(Icons.mail_outline, p.email),
          row(Icons.phone_outlined, p.whatsapp),
          row(Icons.badge_outlined, p.codiceFiscale),
          row(
              Icons.home_outlined,
              [p.indirizzoVia, p.indirizzoPaese, p.indirizzoCap]
                  .where((s) => s != null && s.isNotEmpty)
                  .join(', ')),
          if (p.medicalCertExpiry != null)
            row(
                Icons.medical_information_outlined,
                'Cert. medico: '
                '${p.medicalCertExpiry!.day.toString().padLeft(2, '0')}/'
                '${p.medicalCertExpiry!.month.toString().padLeft(2, '0')}/'
                '${p.medicalCertExpiry!.year}'),
        ],
      ),
    );
  }
}

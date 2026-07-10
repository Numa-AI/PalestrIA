import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/org/org_settings_service.dart';
import '../../core/theme/org_theme.dart';
import '../../core/theme/tokens.dart';
import '../shared/area_switch.dart';
import 'analytics/analytics_tab.dart';
import 'bookings/admin_bookings_tab.dart';
import 'clients/clients_tab.dart';
import 'clients/invite_clients_sheet.dart';
import 'messaggi/messaggi_tab.dart';
import 'payments/payments_tab.dart';
import 'registro/registro_tab.dart';
import 'schede/schede_tab.dart';
import 'schedule/schedule_tab.dart';
import 'settings/settings_tab.dart';

/// Le 9 tab admin (data-tab e label esatte da spec-admin §1.2.1).
enum AdminTab {
  bookings('📅', 'Prenotazioni'),
  payments('💳', 'Pagamenti'),
  analytics('📊', 'Statistiche & Fatturato'),
  schede('🏋🏻', 'Schede'),
  registro('📋', 'Registro'),
  clients('👤', 'Clienti'),
  schedule('⚙️', 'Gestione Orari'),
  messaggi('📩', 'Messaggi'),
  settings('🔧', 'Impostazioni');

  const AdminTab(this.emoji, this.label);
  final String emoji;
  final String label;
}

/// Shell area admin: dock viola in basso (mobile) + sheet "Vai a" — come
/// admin.html §1.4. La tab bar orizzontale/sidebar desktop è secondaria per
/// un'app Play Store mobile-first.
class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({super.key});

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<AdminShell> {
  AdminTab _tab = AdminTab.bookings;

  @override
  Widget build(BuildContext context) {
    ref.watch(orgSettingsProvider);
    final studioName = ref.watch(orgBrandingProvider).studioName;

    final body = switch (_tab) {
      AdminTab.bookings => const AdminBookingsTab(),
      AdminTab.clients => const ClientsTab(),
      AdminTab.payments => const PaymentsTab(),
      AdminTab.analytics => const AnalyticsTab(),
      AdminTab.registro => const RegistroTab(),
      AdminTab.schedule => const ScheduleTab(),
      AdminTab.schede => const SchedeTab(),
      AdminTab.messaggi => const MessaggiTab(),
      AdminTab.settings => const SettingsTab(),
    };

    return Scaffold(
      backgroundColor: AppColors.slateBg,
      appBar: AppBar(
        title: (studioName == null || studioName.trim().isEmpty)
            ? Text(_tab.label)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_tab.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(studioName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.meta),
                ],
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1),
            tooltip: 'Invita clienti',
            onPressed: () => showInviteClientsSheet(context),
          ),
          const UserAreaButton(),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Esci',
            onPressed: () async {
              await ref.read(authRepositoryProvider).logout();
              await ref.read(orgBrandingProvider.notifier).reset();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            left: AppSpacing.md,
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: SafeArea(top: false, child: _dock()),
          ),
        ],
      ),
    );
  }

  Widget _dock() {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: _openPagesSheet,
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [primary, Theme.of(context).colorScheme.secondary],
          ),
          borderRadius: BorderRadius.circular(AppRadius.cardLg),
          boxShadow: [
            BoxShadow(
                color: primary.withValues(alpha: 0.4),
                blurRadius: 16,
                offset: const Offset(0, 6)),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x33FFFFFF),
                borderRadius: BorderRadius.circular(AppRadius.buttonAdmin),
              ),
              child: Text(_tab.emoji, style: const TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SEZIONE',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: Color(0xC7FFFFFF))),
                  Text(_tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_up, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Future<void> _openPagesSheet() async {
    final primary = Theme.of(context).colorScheme.primary;
    final choice = await showModalBottomSheet<AdminTab>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text('VAI A', style: AppText.eyebrow),
            ),
            for (final t in AdminTab.values)
              ListTile(
                tileColor:
                    t == _tab ? primary.withValues(alpha: 0.12) : null,
                leading: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.slateBg,
                    borderRadius: BorderRadius.circular(AppRadius.buttonAdmin),
                  ),
                  child: Text(t.emoji),
                ),
                title: Text(t.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                trailing: Icon(
                  t == _tab
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: t == _tab ? primary : AppColors.subtle,
                  size: 22,
                ),
                onTap: () => Navigator.pop(ctx, t),
              ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
    if (choice != null) setState(() => _tab = choice);
  }
}

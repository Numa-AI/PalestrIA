import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_providers.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/data/schedule_config.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/ui_kit.dart';

final staffTodayBookingsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final org = await ref.watch(orgContextProvider.future);
  if (org.orgId == null || org.orgRole != 'staff') return const [];
  final today = OrgScheduleConfig.localDateStr(DateTime.now());
  final rows = await ref
      .read(supabaseProvider)
      .from('bookings')
      .select('id,time,slot_type,name,status')
      .eq('org_id', org.orgId!)
      .eq('date', today)
      .inFilter('status', ['confirmed', 'cancellation_requested'])
      .order('time');
  return [for (final row in rows) (row as Map).cast<String, dynamic>()];
});

class StaffScreen extends ConsumerWidget {
  const StaffScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookings = ref.watch(staffTodayBookingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agenda staff · Oggi'),
        actions: [
          IconButton(
            tooltip: 'Esci',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(authRepositoryProvider).logout();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(staffTodayBookingsProvider),
        child: bookings.when(
          loading: () => ListView(children: const [AppLoading()]),
          error: (error, _) => ListView(
            children: [
              AppErrorRetry(
                message: 'Agenda non disponibile: $error',
                onRetry: () => ref.invalidate(staffTodayBookingsProvider),
              ),
            ],
          ),
          data: (rows) => ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              const Text(
                'Accesso operativo in sola lettura',
                style: AppText.meta,
              ),
              const SizedBox(height: AppSpacing.md),
              if (rows.isEmpty)
                const AppEmptyState(
                  title: 'Nessuna prenotazione per oggi',
                  icon: Icons.event_available_outlined,
                )
              else
                for (final row in rows)
                  AppCard(
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: ListTile(
                      leading: const Icon(Icons.schedule),
                      title: Text((row['name'] as String?) ?? 'Cliente'),
                      subtitle: Text((row['slot_type'] as String?) ?? ''),
                      trailing: Text((row['time'] as String?) ?? ''),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

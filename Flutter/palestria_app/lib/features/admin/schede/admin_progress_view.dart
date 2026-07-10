import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../client/workout/progress_view.dart';
import 'schede_providers.dart';

/// Vista Progressi di un cliente lato ADMIN (parità col web Schede → Clienti →
/// Progressi): per ogni esercizio una card con Max/Ultimo/Trend; tap → popup
/// zoom (video + grafico kg/ripetizioni/serie/tutti), riusando la logica del
/// Progressi cliente (`buildProgressGroups` / `showProgressZoom`).
class AdminClientProgressScreen extends ConsumerWidget {
  const AdminClientProgressScreen({
    super.key,
    required this.userId,
    required this.title,
  });

  final String userId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plansAsync = ref.watch(orgPlansProvider);
    final logsAsync = ref.watch(adminClientLogsProvider(userId));

    return Scaffold(
      backgroundColor: AppColors.slateBg,
      appBar: AppBar(title: Text('Progressi · $title')),
      body: plansAsync.when(
        loading: () => const AppLoading(),
        error: (e, _) => AppErrorRetry(
          message: 'Errore: $e',
          onRetry: () => ref.invalidate(orgPlansProvider),
        ),
        data: (allPlans) {
          final plans =
              allPlans.where((p) => p.userId == userId).toList();
          return logsAsync.when(
            loading: () => const AppLoading(),
            error: (e, _) => AppErrorRetry(
              message: 'Errore: $e',
              onRetry: () => ref.invalidate(adminClientLogsProvider(userId)),
            ),
            data: (logs) {
              final groups = buildProgressGroups(plans, logs);
              final sessions = logs.map((l) => l.logDate).toSet().length;
              final series = logs.length;
              final volume = logs.fold<double>(
                  0, (s, l) => s + (l.repsDone ?? 0) * (l.weightDone ?? 0));
              final volStr = volume >= 1000
                  ? '${(volume / 1000).toStringAsFixed(1)}t'
                  : '${volume.toStringAsFixed(0)}kg';

              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(orgPlansProvider);
                  ref.invalidate(adminClientLogsProvider(userId));
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, AppSpacing.md, AppSpacing.md, 40),
                  children: [
                    Row(
                      children: [
                        _statCard('📊', '$sessions', 'Sessioni'),
                        const SizedBox(width: AppSpacing.sm),
                        _statCard('🏋️', '$series', 'Serie totali'),
                        const SizedBox(width: AppSpacing.sm),
                        _statCard('📈', volStr, 'Volume'),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (groups.isEmpty)
                      const AppEmptyState(
                        title: 'Nessun log registrato da questo cliente.',
                        icon: Icons.timeline_outlined,
                      )
                    else
                      for (final g in groups) _card(context, g),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _statCard(String icon, String value, String label) => Expanded(
        child: AppCard(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Column(
            children: [
              Text(icon, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.navy)),
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.muted)),
            ],
          ),
        ),
      );

  Widget _card(BuildContext context, ProgressGroup g) {
    String fmt(double v) =>
        v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    final trend = g.trend;
    final trendStr =
        '${trend > 0 ? '+' : trend < 0 ? '−' : ''}${fmt(trend.abs())}';
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: () => showProgressZoom(context, g),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(g.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: AppColors.navy)),
              ),
              Text('${g.sessionCount} sess',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.muted)),
              const SizedBox(width: 6),
              const Icon(Icons.open_in_full, size: 15, color: AppColors.subtle),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Max ${fmt(g.max)}${g.unit}', style: _st),
              Text('Ultimo ${fmt(g.last)}${g.unit}', style: _st),
              Text('Trend $trendStr${g.unit}',
                  style: _st.copyWith(
                      fontWeight: FontWeight.w700,
                      color: trend >= 0
                          ? AppColors.successEmeraldDark
                          : AppColors.dangerDark)),
            ],
          ),
        ],
      ),
    );
  }

  static const _st = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.muted,
      fontFeatures: AppText.tabularNums);
}

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../booking/booking_providers.dart';
import 'exercise_media.dart';
import 'workout_providers.dart';

/// Tutti i log dell'utente su tutti i piani (per Progressi/Storico).
final allLogsProvider = FutureProvider<List<WorkoutLog>>((ref) async {
  final plans = await ref.watch(ownPlansProvider.future);
  final ids = [for (final p in plans) ...p.exercises.map((e) => e.id)];
  return ref.read(workoutRepositoryProvider).fetchLogsForExercises(ids);
});

/// Media (video/immagine) di un singolo esercizio del catalogo per slug — usata
/// dal popup zoom dei Progressi.
final progressMediaProvider = FutureProvider.autoDispose
    .family<CatalogMedia?, String>((ref, slug) async {
      if (slug.isEmpty) return null;
      final rows = await ref
          .read(supabaseProvider)
          .from('imported_exercises')
          .select('immagine, immagine_thumbnail, video')
          .eq('slug', slug)
          .limit(1)
          .timeout(const Duration(seconds: 15));
      if (rows.isEmpty) return null;
      final r = rows.first;
      return CatalogMedia(
        image: r['immagine'] as String?,
        thumbnail: r['immagine_thumbnail'] as String?,
        video: r['video'] as String?,
      );
    });

/// Gruppo progressi: un esercizio (per slug, fallback nome normalizzato).
/// Per ogni data di sessione raccoglie: max kg, media reps/serie, n° serie, e
/// (cardio) max minuti — così il popup può mostrare kg / ripetizioni / serie /
/// tutti, come il web.
class ProgressGroup {
  ProgressGroup({
    required this.key,
    required this.name,
    required this.exercises,
    required this.isCardio,
    required this.weights,
    required this.repsAvg,
    required this.setsCnt,
    required this.minutes,
  });

  final String key;
  final String name;
  final List<WorkoutExercise> exercises;
  final bool isCardio;
  final Map<String, double> weights; // date → max kg
  final Map<String, double> repsAvg; // date → media reps per serie
  final Map<String, int> setsCnt; // date → n° serie loggate
  final Map<String, double> minutes; // date → max minuti (cardio)

  bool get hasKg => weights.isNotEmpty;

  /// Metrica principale della card: minuti (cardio), altrimenti kg se presenti,
  /// altrimenti reps (corpo libero).
  Map<String, double> get _primaryMap =>
      isCardio ? minutes : (hasKg ? weights : repsAvg);

  String get unit => isCardio ? 'min' : (hasKg ? 'kg' : ' rip');

  List<String> get _primaryDates => _primaryMap.keys.toList()..sort();

  /// Date (ordinate) di tutte le sessioni con almeno una serie loggata.
  List<String> get allDates => setsCnt.keys.toList()..sort();

  List<double> get points => _primaryDates.map((d) => _primaryMap[d]!).toList();

  int get sessionCount => _primaryMap.length;

  double get max => points.isEmpty ? 0 : points.reduce((a, b) => a > b ? a : b);
  double get last => points.isEmpty ? 0 : points.last;
  double get trend => points.length < 2 ? 0 : points.last - points.first;
}

String _groupKey(WorkoutExercise e) =>
    (e.exerciseSlug != null && e.exerciseSlug!.isNotEmpty)
    ? e.exerciseSlug!
    : e.exerciseName.trim().toLowerCase();

List<ProgressGroup> buildProgressGroups(
  List<WorkoutPlan> plans,
  List<WorkoutLog> logs, {
  DateTime? from,
  String? muscle,
}) {
  final byId = <String, WorkoutExercise>{};
  for (final p in plans) {
    for (final e in p.exercises) {
      byId[e.id] = e;
    }
  }
  final groups = <String, ProgressGroup>{};
  final repsSum = <String, Map<String, double>>{}; // key → date → somma reps
  final repsCnt =
      <String, Map<String, int>>{}; // key → date → n° serie con reps
  for (final l in logs) {
    final e = byId[l.exerciseId];
    if (e == null) continue;
    if (muscle != null && e.muscleGroup != muscle) continue;
    if (from != null && DateTime.parse(l.logDate).isBefore(from)) continue;
    final key = _groupKey(e);
    final g = groups.putIfAbsent(
      key,
      () => ProgressGroup(
        key: key,
        name: e.exerciseName,
        exercises: [],
        isCardio: e.isCardio,
        weights: {},
        repsAvg: {},
        setsCnt: {},
        minutes: {},
      ),
    );
    if (!g.exercises.contains(e)) g.exercises.add(e);
    final d = l.logDate;
    g.setsCnt[d] = (g.setsCnt[d] ?? 0) + 1;
    if (l.weightDone != null) {
      final cur = g.weights[d];
      if (cur == null || l.weightDone! > cur) g.weights[d] = l.weightDone!;
    }
    if (g.isCardio && l.repsDone != null) {
      final m = l.repsDone!.toDouble();
      final cur = g.minutes[d];
      if (cur == null || m > cur) g.minutes[d] = m;
    }
    if (l.repsDone != null) {
      (repsSum[key] ??= {})[d] = (repsSum[key]![d] ?? 0) + l.repsDone!;
      (repsCnt[key] ??= {})[d] = (repsCnt[key]![d] ?? 0) + 1;
    }
  }
  // Finalizza la media reps/serie.
  for (final entry in groups.entries) {
    final sums = repsSum[entry.key];
    final cnts = repsCnt[entry.key];
    if (sums == null || cnts == null) continue;
    for (final d in sums.keys) {
      final c = cnts[d] ?? 0;
      if (c > 0) {
        entry.value.repsAvg[d] = (sums[d]! / c * 10).roundToDouble() / 10;
      }
    }
  }
  final list = groups.values.where((g) => g.points.isNotEmpty).toList()
    ..sort((a, b) => b.sessionCount.compareTo(a.sessionCount));
  return list;
}

/// Vista PROGRESSI mobile v2 (§8.7).
class ProgressView extends ConsumerStatefulWidget {
  const ProgressView({super.key, required this.onOpenHistory});

  final VoidCallback onOpenHistory;

  @override
  ConsumerState<ProgressView> createState() => _ProgressViewState();
}

class _ProgressViewState extends ConsumerState<ProgressView> {
  int _periodDays = 30; // 0 = tutto
  String? _muscle;

  static const _periods = {
    0: 'Tutto',
    7: 'Ultimi 7 giorni',
    30: 'Ultimi 30 giorni',
    90: 'Ultimi 3 mesi',
  };

  String get _periodEyebrow => switch (_periodDays) {
    7 => ' · ULTIMI 7 GG',
    30 => ' · ULTIMI 30 GG',
    90 => ' · ULTIMI 3 MESI',
    _ => ' · TUTTO',
  };

  @override
  Widget build(BuildContext context) {
    final plans = ref.watch(ownPlansProvider).value ?? const <WorkoutPlan>[];
    final logsAsync = ref.watch(allLogsProvider);
    final bookings = ref.watch(ownBookingsProvider).value ?? const [];

    return logsAsync.when(
      loading: () => const AppLoading(),
      error: (_, _) => AppErrorRetry(
        message: 'Errore caricamento storico.',
        onRetry: () => ref.invalidate(allLogsProvider),
      ),
      data: (logs) {
        final from = _periodDays == 0
            ? null
            : DateTime.now().subtract(Duration(days: _periodDays));
        final groups = buildProgressGroups(
          plans,
          logs,
          from: from,
          muscle: _muscle,
        );

        // KPI
        final periodLogs = logs.where(
          (l) => from == null || !DateTime.parse(l.logDate).isBefore(from),
        );
        final sessions = periodLogs.map((l) => l.logDate).toSet().length;
        final series = periodLogs.length;
        final volume = periodLogs.fold<double>(
          0,
          (sum, l) => sum + (l.repsDone ?? 0) * (l.weightDone ?? 0),
        );
        final now = DateTime.now();
        final trainings = bookings
            .where(
              (b) =>
                  b.isOccupying &&
                  lessonStart(b.date, b.time).isBefore(now) &&
                  (from == null || !DateTime.parse(b.date).isBefore(from)),
            )
            .map((b) => b.date)
            .toSet()
            .length;

        final muscles = {
          for (final p in plans)
            for (final e in p.exercises)
              if (e.muscleGroup != null && e.muscleGroup!.isNotEmpty)
                e.muscleGroup!,
        }.toList()..sort();

        return Stack(
          children: [
            ListView(
              padding: EdgeInsets.zero,
              children: [
                _hero(trainings, sessions, series, volume),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    4,
                  ),
                  child: Text(
                    'ESERCIZI · ${groups.length}',
                    style: AppText.eyebrow,
                  ),
                ),
                if (groups.isEmpty)
                  AppEmptyState(
                    compact: true,
                    title: _muscle == null
                        ? 'Nessun esercizio registrato${_periodLabelSuffix()}.'
                        : 'Nessun esercizio per "$_muscle"${_periodLabelSuffix()}.',
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    child: Column(
                      children: [for (final g in groups) _exCard(g)],
                    ),
                  ),
                const SizedBox(height: 140),
              ],
            ),
            // FAB filtro muscolo
            Positioned(
              left: 0,
              right: 0,
              bottom: 96,
              child: Center(
                child: GestureDetector(
                  onTap: () => _muscleSheet(muscles),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.navy,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: AppShadows.cardMd,
                    ),
                    child: Text(
                      '🔽 ${_muscle ?? 'Tutti i muscoli'}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _periodLabelSuffix() => switch (_periodDays) {
    7 => ' negli ultimi 7 giorni',
    30 => ' negli ultimi 30 giorni',
    90 => ' negli ultimi 3 mesi',
    _ => '',
  };

  Widget _hero(int trainings, int sessions, int series, double volume) {
    String volumeLabel = volume >= 1000
        ? '${(volume / 1000).toStringAsFixed(1)}t'
        : volume.toStringAsFixed(0);

    Widget kpi(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              fontFeatures: AppText.tabularNums,
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: Color(0xA6FFFFFF)),
          ),
        ],
      ),
    );

    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + AppSpacing.md,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        bottom: AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        gradient: AppGradients.workoutHero,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(18)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _periodSheet,
                  child: Row(
                    children: [
                      Text(
                        'PROGRESSI$_periodEyebrow',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                          color: Color(0xD9C4B5FD),
                        ),
                      ),
                      const Icon(
                        Icons.expand_more,
                        size: 16,
                        color: Color(0xD9C4B5FD),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onOpenHistory,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0x1FFFFFFF),
                ),
                icon: const Icon(Icons.history, size: 18, color: Colors.white),
                tooltip: 'Storico',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              kpi('Allenamenti', '$trainings'),
              kpi('Sessioni', '$sessions'),
              kpi('Serie', '$series'),
              kpi('Volume', volumeLabel),
            ],
          ),
        ],
      ),
    );
  }

  Widget _exCard(ProgressGroup g) {
    final e = g.exercises.first;
    final points = g.points;
    final trend = g.trend;
    final trendStr = trend == 0
        ? '0'
        : '${trend > 0 ? '+' : '−'}${trend.abs() % 1 == 0 ? trend.abs().toStringAsFixed(0) : trend.abs().toStringAsFixed(1)}';

    return InkWell(
      onTap: () => showProgressZoom(context, g),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppColors.border, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: AppColors.navy,
                        ),
                      ),
                      Text(
                        'Target ${e.sets}×${e.reps}${e.weightKg != null && e.weightKg! > 0 ? ' · ${e.weightKg!.toStringAsFixed(e.weightKg! % 1 == 0 ? 0 : 1)}kg' : ''}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.purpleGlow,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${g.sessionCount} sess',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.open_in_full, size: 15, color: AppColors.subtle),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 56,
              child: CustomPaint(
                size: const Size(double.infinity, 56),
                painter: _SparklinePainter(
                  points,
                  Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _stat(
                  'Max',
                  '${g.max % 1 == 0 ? g.max.toStringAsFixed(0) : g.max.toStringAsFixed(1)}${g.unit}',
                ),
                _stat(
                  'Ultimo',
                  '${g.last % 1 == 0 ? g.last.toStringAsFixed(0) : g.last.toStringAsFixed(1)}${g.unit}',
                ),
                Text(
                  'Trend $trendStr${g.unit}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: trend >= 0
                        ? AppColors.successEmeraldDark
                        : AppColors.dangerDark,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Text(
    '$label $value',
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.muted,
      fontFeatures: AppText.tabularNums,
    ),
  );

  Future<void> _periodSheet() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text('PERIODO', style: AppText.eyebrow),
              ),
              for (final entry in _periods.entries)
                ListTile(
                  title: Text(entry.value),
                  trailing: Icon(
                    entry.key == _periodDays
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: entry.key == _periodDays
                        ? primary
                        : AppColors.subtle,
                    size: 22,
                  ),
                  onTap: () => Navigator.pop(ctx, entry.key),
                ),
            ],
          ),
        );
      },
    );
    if (v != null) setState(() => _periodDays = v);
  }

  Future<void> _muscleSheet(List<String> muscles) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text('FILTRA PER MUSCOLO', style: AppText.eyebrow),
            ),
            ListTile(
              title: const Text('Tutti i muscoli'),
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final m in muscles)
              ListTile(title: Text(m), onTap: () => Navigator.pop(ctx, m)),
          ],
        ),
      ),
    );
    if (v != null) setState(() => _muscle = v.isEmpty ? null : v);
  }
}

/// Apre il popup zoom di un esercizio: media (video/immagine) + selettore
/// kg / ripetizioni / serie / tutti + grafico multi-serie + righe stats.
void showProgressZoom(BuildContext context, ProgressGroup g) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ProgressZoomSheet(group: g),
  );
}

/// Metrica del selettore del popup.
enum _ZoomMetric { kg, reps, sets, all }

class _ProgressZoomSheet extends ConsumerStatefulWidget {
  const _ProgressZoomSheet({required this.group});

  final ProgressGroup group;

  @override
  ConsumerState<_ProgressZoomSheet> createState() => _ProgressZoomSheetState();
}

class _ProgressZoomSheetState extends ConsumerState<_ProgressZoomSheet> {
  late _ZoomMetric _mode;

  static const _kg = Color(0xFF1AA6E0);
  static const _reps = Color(0xFFF59E0B);
  static const _sets = Color(0xFF10B981);

  ProgressGroup get g => widget.group;

  bool get _hasKg => g.weights.isNotEmpty;
  bool get _hasReps => g.repsAvg.isNotEmpty;
  bool get _hasSets => g.setsCnt.isNotEmpty;
  bool get _canAll => [_hasKg, _hasReps, _hasSets].where((b) => b).length >= 2;

  @override
  void initState() {
    super.initState();
    _mode = _hasKg
        ? _ZoomMetric.kg
        : (_hasReps ? _ZoomMetric.reps : _ZoomMetric.sets);
  }

  @override
  Widget build(BuildContext context) {
    final slug = g.exercises.first.exerciseSlug ?? '';
    final media = slug.isEmpty
        ? null
        : ref.watch(progressMediaProvider(slug)).value;
    final series = _seriesForMode();

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.navy,
                          ),
                        ),
                        Text(
                          'Target ${g.exercises.first.targetLabel}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    color: AppColors.muted,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (media?.video != null ||
                  media?.image != null ||
                  media?.thumbnail != null)
                ExerciseMediaView(
                  videoUrl: media?.video,
                  imageUrl: media?.image ?? media?.thumbnail,
                  height: 200,
                ),
              const SizedBox(height: AppSpacing.md),
              if (!g.isCardio) _selector(),
              if (!g.isCardio && series.length > 1) ...[
                const SizedBox(height: 8),
                _legend(series),
              ],
              const SizedBox(height: AppSpacing.md),
              Container(
                height: 180,
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                padding: const EdgeInsets.all(12),
                child: CustomPaint(
                  size: const Size(double.infinity, 156),
                  painter: _MultiSeriesPainter(series),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              for (final s in series) _statRow(s),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selector() {
    Widget chip(String label, _ZoomMetric mode, bool enabled, Color accent) {
      final active = _mode == mode;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: GestureDetector(
            onTap: enabled ? () => setState(() => _mode = mode) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? accent.withValues(alpha: 0.12) : Colors.white,
                border: Border.all(
                  color: active ? accent : AppColors.border,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Opacity(
                opacity: enabled ? 1 : 0.4,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? accent : AppColors.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip('Kg', _ZoomMetric.kg, _hasKg, _kg),
        chip('Reps', _ZoomMetric.reps, _hasReps, _reps),
        chip('Serie', _ZoomMetric.sets, _hasSets, _sets),
        chip('Tutti', _ZoomMetric.all, _canAll, AppColors.navy),
      ],
    );
  }

  Widget _legend(List<_ZoomSeries> series) => Wrap(
    spacing: 12,
    runSpacing: 4,
    children: [
      for (final s in series)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: s.color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              s.label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
    ],
  );

  Widget _statRow(_ZoomSeries s) {
    final vals = [for (final v in s.values) ?v];
    if (vals.isEmpty) return const SizedBox.shrink();
    final mx = vals.reduce((a, b) => a > b ? a : b);
    final last = vals.last;
    final tr = vals.length >= 2 ? last - vals.first : 0.0;
    String fmt(double v) =>
        v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: s.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 8),
          Text('Max ${fmt(mx)}${s.unit}', style: _statStyle),
          const SizedBox(width: 12),
          Text('Ultimo ${fmt(last)}${s.unit}', style: _statStyle),
          const SizedBox(width: 12),
          Text(
            'Trend ${tr > 0 ? '+' : ''}${fmt(tr)}${s.unit}',
            style: _statStyle.copyWith(
              color: tr >= 0
                  ? AppColors.successEmeraldDark
                  : AppColors.dangerDark,
            ),
          ),
        ],
      ),
    );
  }

  static const _statStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.muted,
    fontFeatures: AppText.tabularNums,
  );

  List<_ZoomSeries> _seriesForMode() {
    final dates = g.isCardio ? (g.minutes.keys.toList()..sort()) : g.allDates;
    List<double?> alignedFrom(Map<String, num> m) => [
      for (final d in dates) m[d]?.toDouble(),
    ];

    if (g.isCardio) {
      return [_ZoomSeries('Minuti', _kg, ' min', alignedFrom(g.minutes))];
    }
    _ZoomSeries kg() => _ZoomSeries('Kg', _kg, 'kg', alignedFrom(g.weights));
    _ZoomSeries reps() =>
        _ZoomSeries('Ripetizioni', _reps, ' rip', alignedFrom(g.repsAvg));
    _ZoomSeries sets() =>
        _ZoomSeries('Serie', _sets, ' serie', alignedFrom(g.setsCnt));

    switch (_mode) {
      case _ZoomMetric.kg:
        return [kg()];
      case _ZoomMetric.reps:
        return [reps()];
      case _ZoomMetric.sets:
        return [sets()];
      case _ZoomMetric.all:
        return [if (_hasKg) kg(), if (_hasReps) reps(), if (_hasSets) sets()];
    }
  }
}

class _ZoomSeries {
  _ZoomSeries(this.label, this.color, this.unit, this.values);
  final String label;
  final Color color;
  final String unit;
  final List<double?> values; // allineati alle date, null = gap
}

/// Grafico multi-serie: 1-3 polilinee, ognuna normalizzata sulla propria scala,
/// area gradient solo sulla 1ª, tratteggio differenziato (pieno/dash/dot).
class _MultiSeriesPainter extends CustomPainter {
  _MultiSeriesPainter(this.series);
  final List<_ZoomSeries> series;

  static const _dashes = <List<double>>[
    <double>[],
    <double>[7, 5],
    <double>[2, 5],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Griglia orizzontale tratteggiata.
    final gridPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;
    for (var i = 1; i <= 3; i++) {
      final y = size.height * i / 4;
      _dashedLine(canvas, Offset(0, y), Offset(size.width, y), const [
        3,
        4,
      ], gridPaint);
    }

    for (var si = 0; si < series.length; si++) {
      final s = series[si];
      final n = s.values.length;
      final nn = [for (final v in s.values) ?v];
      if (nn.isEmpty) continue;
      final minV = nn.reduce(math.min);
      final maxV = nn.reduce(math.max);
      final range = (maxV - minV) == 0 ? 1.0 : (maxV - minV);

      final pts = <Offset>[];
      for (var i = 0; i < n; i++) {
        final v = s.values[i];
        if (v == null) continue;
        final x = n == 1 ? size.width / 2 : i * size.width / (n - 1);
        final y = (minV == maxV)
            ? size.height / 2
            : size.height - ((v - minV) / range) * (size.height - 10) - 5;
        pts.add(Offset(x, y));
      }
      if (pts.isEmpty) continue;

      // Area gradient solo sulla 1ª serie.
      if (si == 0) {
        final area = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final p in pts.skip(1)) {
          area.lineTo(p.dx, p.dy);
        }
        area
          ..lineTo(pts.last.dx, size.height)
          ..lineTo(pts.first.dx, size.height)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                s.color.withValues(alpha: 0.24),
                s.color.withValues(alpha: 0.02),
              ],
            ).createShader(Offset.zero & size),
        );
      }

      final line = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        line.lineTo(p.dx, p.dy);
      }
      final linePaint = Paint()
        ..color = s.color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final dash = _dashes[si % _dashes.length];
      if (dash.isEmpty) {
        canvas.drawPath(line, linePaint);
      } else {
        _dashedPath(canvas, line, dash, linePaint);
      }

      for (final o in [pts.first, pts.last]) {
        canvas.drawCircle(o, 4, Paint()..color = Colors.white);
        canvas.drawCircle(
          o,
          4,
          Paint()
            ..color = s.color
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  void _dashedLine(Canvas c, Offset a, Offset b, List<double> dash, Paint p) {
    _dashedPath(
      c,
      Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy),
      dash,
      p,
    );
  }

  void _dashedPath(Canvas c, Path path, List<double> dash, Paint p) {
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      var draw = true;
      var di = 0;
      while (dist < metric.length) {
        final len = dash[di % dash.length];
        final next = (dist + len).clamp(0.0, metric.length);
        if (draw) c.drawPath(metric.extractPath(dist, next), p);
        dist = next;
        draw = !draw;
        di++;
      }
    }
  }

  @override
  bool shouldRepaint(_MultiSeriesPainter oldDelegate) => true;
}

/// Sparkline con area gradiente color brand (grafico mobile §8.7). Il colore
/// arriva dal tema (org-aware) invece di un viola fisso.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.points, this.color);

  final List<double> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final maxV = points.reduce((a, b) => a > b ? a : b);
    final minV = points.reduce((a, b) => a < b ? a : b);
    final range = (maxV - minV) == 0 ? 1.0 : (maxV - minV);

    Offset pt(int i) {
      final x = points.length == 1
          ? size.width / 2
          : i * size.width / (points.length - 1);
      final y =
          size.height - ((points[i] - minV) / range) * (size.height - 8) - 4;
      return Offset(x, y);
    }

    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < points.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }

    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.2), color.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
    for (final i in [0, points.length - 1]) {
      canvas.drawCircle(pt(i), 3.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        pt(i),
        3.5,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}

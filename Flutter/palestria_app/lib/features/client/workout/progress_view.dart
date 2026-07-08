import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import '../booking/booking_providers.dart';
import 'workout_providers.dart';

/// Tutti i log dell'utente su tutti i piani (per Progressi/Storico).
final allLogsProvider = FutureProvider<List<WorkoutLog>>((ref) async {
  final plans = await ref.watch(ownPlansProvider.future);
  final ids = [for (final p in plans) ...p.exercises.map((e) => e.id)];
  return ref.read(workoutRepositoryProvider).fetchLogsForExercises(ids);
});

/// Gruppo progressi: un esercizio (per slug, fallback nome normalizzato).
class ProgressGroup {
  ProgressGroup({
    required this.key,
    required this.name,
    required this.exercises,
    required this.sessions, // data → valore (max kg o max min cardio)
    required this.isCardio,
  });

  final String key;
  final String name;
  final List<WorkoutExercise> exercises;
  final Map<String, double> sessions;
  final bool isCardio;

  String get unit => isCardio ? 'min' : 'kg';
  List<MapEntry<String, double>> get ordered =>
      sessions.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

  double get max =>
      sessions.values.isEmpty ? 0 : sessions.values.reduce((a, b) => a > b ? a : b);
  double get last => ordered.isEmpty ? 0 : ordered.last.value;
  double get trend => ordered.length < 2
      ? 0
      : ordered.last.value - ordered[ordered.length - 2].value;
}

String _groupKey(WorkoutExercise e) =>
    (e.exerciseSlug != null && e.exerciseSlug!.isNotEmpty)
        ? e.exerciseSlug!
        : e.exerciseName.trim().toLowerCase();

List<ProgressGroup> buildProgressGroups(
    List<WorkoutPlan> plans, List<WorkoutLog> logs,
    {DateTime? from, String? muscle}) {
  final byId = <String, WorkoutExercise>{};
  for (final p in plans) {
    for (final e in p.exercises) {
      byId[e.id] = e;
    }
  }
  final groups = <String, ProgressGroup>{};
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
              sessions: {},
              isCardio: e.isCardio,
            ));
    if (!g.exercises.contains(e)) g.exercises.add(e);
    final value = g.isCardio
        ? (l.repsDone ?? 0).toDouble()
        : (l.weightDone ?? 0);
    final current = g.sessions[l.logDate] ?? 0;
    if (value > current) g.sessions[l.logDate] = value;
  }
  final list = groups.values.where((g) => g.sessions.isNotEmpty).toList()
    ..sort((a, b) => b.sessions.length.compareTo(a.sessions.length));
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) =>
          const Center(child: Text('Errore caricamento storico.')),
      data: (logs) {
        final from = _periodDays == 0
            ? null
            : DateTime.now().subtract(Duration(days: _periodDays));
        final groups =
            buildProgressGroups(plans, logs, from: from, muscle: _muscle);

        // KPI
        final periodLogs = logs.where((l) =>
            from == null || !DateTime.parse(l.logDate).isBefore(from));
        final sessions = periodLogs.map((l) => l.logDate).toSet().length;
        final series = periodLogs.length;
        final volume = periodLogs.fold<double>(
            0, (sum, l) => sum + (l.repsDone ?? 0) * (l.weightDone ?? 0));
        final now = DateTime.now();
        final trainings = bookings
            .where((b) =>
                b.isOccupying &&
                lessonStart(b.date, b.time).isBefore(now) &&
                (from == null || !DateTime.parse(b.date).isBefore(from)))
            .map((b) => b.date)
            .toSet()
            .length;

        final muscles = {
          for (final p in plans)
            for (final e in p.exercises)
              if (e.muscleGroup != null && e.muscleGroup!.isNotEmpty)
                e.muscleGroup!
        }.toList()
          ..sort();

        return Stack(
          children: [
            ListView(
              padding: EdgeInsets.zero,
              children: [
                _hero(trainings, sessions, series, volume),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 4),
                  child: Text('ESERCIZI · ${groups.length}',
                      style: AppText.eyebrow),
                ),
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.xxl),
                    child: Text(
                      _muscle == null
                          ? 'Nessun esercizio registrato${_periodLabelSuffix()}.'
                          : 'Nessun esercizio per "$_muscle"${_periodLabelSuffix()}.',
                      textAlign: TextAlign.center,
                      style: AppText.meta,
                    ),
                  )
                else
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.md),
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
                        horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(
                      color: AppColors.navy,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: AppShadows.cardMd,
                    ),
                    child: Text('🔽 ${_muscle ?? 'Tutti i muscoli'}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
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
              Text(value,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      fontFeatures: AppText.tabularNums)),
              Text(label,
                  style: const TextStyle(
                      fontSize: 10.5, color: Color(0xA6FFFFFF))),
            ],
          ),
        );

    return Container(
      padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + AppSpacing.md,
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          bottom: AppSpacing.lg),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F172A), Color(0xFF1E1B4B), Color(0xFF7C3AED)],
          stops: [0, 0.6, 1.3],
        ),
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
                      Text('PROGRESSI$_periodEyebrow',
                          style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                              color: Color(0xD9C4B5FD))),
                      const Icon(Icons.expand_more,
                          size: 16, color: Color(0xD9C4B5FD)),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.onOpenHistory,
                style: IconButton.styleFrom(
                    backgroundColor: const Color(0x1FFFFFFF)),
                icon: const Icon(Icons.history,
                    size: 18, color: Colors.white),
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
    final points = g.ordered.map((s) => s.value).toList();
    final trend = g.trend;
    final trendStr = trend == 0
        ? '0'
        : '${trend > 0 ? '+' : '−'}${trend.abs() % 1 == 0 ? trend.abs().toStringAsFixed(0) : trend.abs().toStringAsFixed(1)}';

    return Container(
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
                    Text(g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                            color: AppColors.navy)),
                    Text(
                        'Target ${e.sets}×${e.reps}${e.weightKg != null && e.weightKg! > 0 ? ' · ${e.weightKg!.toStringAsFixed(e.weightKg! % 1 == 0 ? 0 : 1)}kg' : ''}',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.muted)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.purpleGlow,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text('${g.sessions.length} sess',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryDark)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 56,
            child: CustomPaint(
              size: const Size(double.infinity, 56),
              painter: _SparklinePainter(points),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _stat('Max',
                  '${g.max % 1 == 0 ? g.max.toStringAsFixed(0) : g.max.toStringAsFixed(1)}${g.unit}'),
              _stat('Ultimo',
                  '${g.last % 1 == 0 ? g.last.toStringAsFixed(0) : g.last.toStringAsFixed(1)}${g.unit}'),
              Text('Trend $trendStr${g.unit}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: trend >= 0
                          ? const Color(0xFF059669)
                          : const Color(0xFFDC2626))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Text('$label $value',
      style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.muted,
          fontFeatures: AppText.tabularNums));

  Future<void> _periodSheet() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
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
                      ? AppColors.primary
                      : AppColors.subtle,
                  size: 22,
                ),
                onTap: () => Navigator.pop(ctx, entry.key),
              ),
          ],
        ),
      ),
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
              ListTile(
                title: Text(m),
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (v != null) setState(() => _muscle = v.isEmpty ? null : v);
  }
}

/// Sparkline con area gradiente viola (grafico mobile §8.7).
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.points);

  final List<double> points;

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
      final y = size.height -
          ((points[i] - minV) / range) * (size.height - 8) -
          4;
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
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x338B5CF6), Color(0x058B5CF6)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = const Color(0xFF8B5CF6)
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
            ..color = const Color(0xFF8B5CF6)
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.points != points;
}

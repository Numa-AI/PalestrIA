import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import 'add_exercise_flows.dart';
import 'exercise_detail_sheet.dart';
import 'history_view.dart';
import 'progress_view.dart';
import 'report_view.dart';
import 'tablet_qr_view.dart';
import 'workout_pdf.dart';
import 'workout_providers.dart';

/// Sezioni dell'area Allenamento (come sessionStorage.allView del web).
enum WorkoutSection { scheda, progressi, storico, report, tablet }

/// Host dell'area Allenamento: dock in basso per cambiare sezione
/// (port del dock mobile + sheet "Vai a" di allenamento.html §8.2).
class WorkoutScreen extends ConsumerStatefulWidget {
  const WorkoutScreen({super.key});

  @override
  ConsumerState<WorkoutScreen> createState() => _WorkoutScreenHostState();
}

class _WorkoutScreenHostState extends ConsumerState<WorkoutScreen> {
  WorkoutSection _section = WorkoutSection.scheda;

  static const _titles = {
    WorkoutSection.scheda: 'Scheda',
    WorkoutSection.progressi: 'Progressi',
    WorkoutSection.storico: 'Storico',
    WorkoutSection.report: 'Report',
    WorkoutSection.tablet: 'Tablet',
  };

  static const _emojis = {
    WorkoutSection.scheda: '📋',
    WorkoutSection.progressi: '📈',
    WorkoutSection.storico: '📈',
    WorkoutSection.report: '📊',
    WorkoutSection.tablet: '📱',
  };

  @override
  Widget build(BuildContext context) {
    final body = switch (_section) {
      WorkoutSection.scheda => const SchedaView(),
      WorkoutSection.progressi => ProgressView(
          onOpenHistory: () =>
              setState(() => _section = WorkoutSection.storico)),
      WorkoutSection.storico => HistoryView(
          onBack: () => setState(() => _section = WorkoutSection.progressi)),
      WorkoutSection.report => const ReportView(),
      WorkoutSection.tablet => const TabletQrView(),
    };

    return Scaffold(
      backgroundColor: AppColors.slateBg,
      body: Stack(
        children: [
          body,
          // Dock sezione (solo fuori dallo storico, che ha il suo back)
          if (_section != WorkoutSection.storico)
            Positioned(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              bottom: AppSpacing.md,
              child: SafeArea(
                top: false,
                child: GestureDetector(
                  onTap: _openSectionSheet,
                  child: Container(
                    height: 56,
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF7C3AED), Color(0xFF8B5CF6)],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x668B5CF6),
                            blurRadius: 16,
                            offset: Offset(0, 6)),
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
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(_emojis[_section]!,
                              style: const TextStyle(fontSize: 18)),
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
                              Text(_titles[_section]!,
                                  style: const TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white)),
                            ],
                          ),
                        ),
                        const Icon(Icons.keyboard_arrow_up,
                            color: Colors.white),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openSectionSheet() async {
    final choice = await showModalBottomSheet<WorkoutSection>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text('VAI A', style: AppText.eyebrow),
            ),
            _sheetItem(ctx, WorkoutSection.scheda, '📋', 'Scheda'),
            _sheetItem(ctx, WorkoutSection.progressi, '📈', 'Progressi'),
            _sheetItem(ctx, WorkoutSection.report, '📊', 'Report'),
            _sheetItem(ctx, WorkoutSection.tablet, '📱', 'Tablet'),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
    if (choice != null) setState(() => _section = choice);
  }

  Widget _sheetItem(
      BuildContext ctx, WorkoutSection section, String emoji, String title) {
    final selected = _section == section;
    return ListTile(
      tileColor: selected ? AppColors.purpleGlow : null,
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.slateBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(emoji),
      ),
      title: Text(title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? AppColors.primary : AppColors.subtle,
        size: 22,
      ),
      onTap: () => Navigator.pop(ctx, section),
    );
  }
}

/// Vista SCHEDA (port di allenamento.html §8.3): hero scura con rail giorni,
/// card esercizio/superset/circuito, stato "fatto oggi".
class SchedaView extends ConsumerStatefulWidget {
  const SchedaView({super.key});

  @override
  ConsumerState<SchedaView> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends ConsumerState<SchedaView> {
  String? _planId;
  String? _dayLabel;
  bool _pdfBusy = false;

  /// true se l'utente può modificare la STRUTTURA delle schede (creare/rinominare/
  /// eliminare scheda ed esercizi). I log serie/peso restano sempre consentiti.
  /// Vale per gli admin/trainer, oppure per i clienti se il trainer ha attivato
  /// il flag org `features.client_manage_plans` (default: solo trainer).
  /// NB: quando ON per i clienti serve anche la policy RLS lato DB (vedi todo).
  bool _canManage = false;

  Future<void> _exportPdf(WorkoutPlan plan) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _pdfBusy = true);
    try {
      final userName = ref.read(userProfileProvider).value?.name;
      await shareWorkoutPdf(plan, userName: userName);
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Errore nella generazione del PDF: $e')));
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plansAsync = ref.watch(ownPlansProvider);
    _canManage =
        (ref.watch(orgContextProvider).value?.isOrgAdmin ?? false) ||
            (ref.watch(orgSettingsProvider).value?.getBool(
                    'features.client_manage_plans', false) ??
                false);

    return Scaffold(
      backgroundColor: AppColors.slateBg,
      body: plansAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            const Center(child: Text('Errore caricamento scheda.')),
        data: (plans) {
          if (plans.isEmpty) return _emptyState();

          final plan = plans.firstWhere((p) => p.id == _planId,
              orElse: () => plans.first);
          final days = plan.dayLabels;
          final day = days.contains(_dayLabel)
              ? _dayLabel!
              : (days.isEmpty ? '' : days.first);

          final logsAsync = ref.watch(planLogsProvider(plan.id));
          final logs = logsAsync.value ?? const <WorkoutLog>[];
          final mediaAsync = ref.watch(catalogMediaProvider(plan.id));
          final media = mediaAsync.value ?? const <String, CatalogMedia>{};

          final dayExercises = plan.exercisesOf(day);
          final groups = groupExercises(dayExercises);
          final doneCount =
              dayExercises.where((e) => doneToday(e, logs)).length;

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(ownPlansProvider);
              ref.invalidate(planLogsProvider(plan.id));
            },
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _hero(plan, plans, days, day, logs),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(day,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: AppColors.navy)),
                      Text('$doneCount/${dayExercises.length} completati',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.muted)),
                    ],
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Column(
                    children: [
                      for (final g in groups)
                        _groupCard(context, plan, g, logs, media),
                    ],
                  ),
                ),
                const SizedBox(height: 100),
              ],
            ),
          );
        },
      ),
      // FAB sopra il dock sezione (come il web: bottom 84px + safe-area).
      // Solo chi può gestire la struttura scheda (crea/aggiungi esercizi).
      floatingActionButton: !_canManage
          ? null
          : Padding(
        padding: const EdgeInsets.only(bottom: 64),
        child: FloatingActionButton(
          onPressed: () => _fabAction(plansAsync.value ?? const []),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Nessuna scheda ancora.',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.navy)),
              const SizedBox(height: 6),
              Text(
                  _canManage
                      ? 'Premi il + in basso per crearne una!'
                      : 'Il tuo trainer non ti ha ancora assegnato una scheda.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted)),
            ],
          ),
        ),
      );

  /// Hero mobile §8.3: gradiente #0f172a → #1e1b4b → #7C3AED.
  Widget _hero(WorkoutPlan plan, List<WorkoutPlan> plans, List<String> days,
      String activeDay, List<WorkoutLog> logs) {
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SCHEDA',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Color(0xD9C4B5FD))),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(plan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
              ),
              if (_canManage) ...[
                IconButton(
                  onPressed: () => _renamePlan(plan),
                  style: IconButton.styleFrom(
                      backgroundColor: const Color(0x1FFFFFFF)),
                  icon: const Icon(Icons.edit, size: 16, color: Colors.white),
                ),
                const SizedBox(width: 6),
              ],
              IconButton(
                onPressed: _pdfBusy ? null : () => _exportPdf(plan),
                style: IconButton.styleFrom(
                    backgroundColor: const Color(0x1FFFFFFF)),
                tooltip: 'Scarica PDF',
                icon: _pdfBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.picture_as_pdf,
                        size: 16, color: Colors.white),
              ),
            ],
          ),
          if (plans.length > 1)
            DropdownButton<String>(
              value: plan.id,
              dropdownColor: const Color(0xFF1E1B4B),
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
              underline: const SizedBox.shrink(),
              items: [
                for (final p in plans)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text('${p.name}${p.active ? ' (attiva)' : ''}'),
                  ),
              ],
              onChanged: (v) => setState(() {
                _planId = v;
                _dayLabel = null;
              }),
            ),
          const SizedBox(height: AppSpacing.md),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final d in days) _dayChip(plan, d, d == activeDay, logs),
                // Chip "+" tratteggiato: nuovo giorno (solo chi gestisce la scheda)
                if (_canManage)
                  GestureDetector(
                  onTap: () => addDayToScheda(context, ref, plan),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: const Color(0x4DFFFFFF), width: 1.5),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Text('+',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayChip(
      WorkoutPlan plan, String day, bool active, List<WorkoutLog> logs) {
    final last = lastLogDate(plan.exercisesOf(day), logs);
    String meta;
    if (last == null) {
      meta = 'ultimo · mai';
    } else if (last == todayYmd()) {
      meta = 'ultimo · oggi';
    } else {
      final d = DateTime.parse(last);
      meta =
          'ultimo · ${d.day} ${_monthShort[d.month - 1]}';
    }

    return GestureDetector(
      onTap: () => setState(() => _dayLabel = day),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.white : const Color(0x14FFFFFF),
          border: Border.all(color: const Color(0x1AFFFFFF)),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(day,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: active ? const Color(0xFF0F172A) : Colors.white)),
            Text(meta,
                style: TextStyle(
                    fontSize: 10,
                    color: active
                        ? const Color(0xFF64748B)
                        : const Color(0xA6FFFFFF))),
          ],
        ),
      ),
    );
  }

  Widget _groupCard(BuildContext context, WorkoutPlan plan, ExerciseGroup g,
      List<WorkoutLog> logs, Map<String, CatalogMedia> media) {
    final allDone = g.exercises.every((e) => doneToday(e, logs));

    Widget thumb(WorkoutExercise e, {double size = 44}) {
      final url = e.exerciseSlug == null
          ? null
          : (media[e.exerciseSlug!]?.thumbnail ?? media[e.exerciseSlug!]?.image);
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: url == null
            ? Container(
                width: size,
                height: size,
                color: AppColors.slateBg,
                child: const Icon(Icons.fitness_center,
                    size: 20, color: AppColors.subtle),
              )
            : CachedNetworkImage(
                imageUrl: url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Container(
                    width: size,
                    height: size,
                    color: AppColors.slateBg,
                    child: const Icon(Icons.fitness_center,
                        size: 20, color: AppColors.subtle)),
              ),
      );
    }

    Widget badge(String text, List<Color> colors) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(text,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Colors.white)),
        );

    String title;
    String meta;
    Widget leading;
    switch (g.kind) {
      case ExerciseGroupKind.single:
        title = g.first.exerciseName;
        meta = g.first.targetLabel;
        leading = thumb(g.first);
      case ExerciseGroupKind.superset:
        title = g.exercises.map((e) => e.exerciseName).join(' + ');
        meta = 'Super Serie';
        leading = Column(
          children: [
            thumb(g.exercises[0], size: 26),
            const SizedBox(height: 2),
            if (g.exercises.length > 1) thumb(g.exercises[1], size: 26),
          ],
        );
      case ExerciseGroupKind.circuit:
        final rest = g.exercises
            .map((e) => e.restSeconds)
            .where((r) => r > 0)
            .fold<int>(0, (a, b) => b);
        title = g.exercises.map((e) => e.exerciseName).join(' · ');
        meta =
            '${g.first.sets} giri${rest > 0 ? ' · ${rest}s pausa' : ''}';
        leading = thumb(g.first);
    }

    return Dismissible(
      key: ValueKey(g.first.id),
      // Swipe-per-eliminare solo per chi gestisce la struttura scheda.
      direction:
          _canManage ? DismissDirection.endToStart : DismissDirection.none,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.danger,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDeleteGroup(g),
      onDismissed: (_) => _deleteGroup(plan, g),
      child: GestureDetector(
        onTap: () => showExerciseDetailSheet(context, ref, plan, g),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: 14),
          decoration: BoxDecoration(
            gradient: allDone
                ? const LinearGradient(
                    colors: [Color(0xFFF0FDF4), Colors.white])
                : null,
            color: allDone ? null : Colors.white,
            border: Border.all(
                color: allDone
                    ? const Color(0xFF10B981)
                    : AppColors.border,
                width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (g.kind == ExerciseGroupKind.superset) ...[
                          badge('SS',
                              const [Color(0xFFF59E0B), Color(0xFFF97316)]),
                          const SizedBox(width: 6),
                        ],
                        if (g.kind == ExerciseGroupKind.circuit) ...[
                          badge('C',
                              const [Color(0xFF06B6D4), Color(0xFF0891B2)]),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.navy)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(meta,
                        style: const TextStyle(
                            fontSize: 12.5, color: AppColors.muted)),
                  ],
                ),
              ),
              if (allDone)
                Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                        colors: [Color(0xFF10B981), Color(0xFF059669)]),
                  ),
                  child:
                      const Icon(Icons.check, size: 18, color: Colors.white),
                )
              else
                const Icon(Icons.chevron_right, color: AppColors.subtle),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool?> _confirmDeleteGroup(ExerciseGroup g) {
    final message = switch (g.kind) {
      ExerciseGroupKind.single =>
        'Eliminare questo esercizio dalla scheda?',
      ExerciseGroupKind.superset =>
        'Eliminare questa super serie dalla scheda?',
      ExerciseGroupKind.circuit => 'Eliminare questo circuito dalla scheda?',
    };
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Elimina')),
        ],
      ),
    );
  }

  Future<void> _deleteGroup(WorkoutPlan plan, ExerciseGroup g) async {
    if (!_canManage) return;
    final repo = ref.read(workoutRepositoryProvider);
    try {
      await repo.deleteExercises([for (final e in g.exercises) e.id]);
      _toast(switch (g.kind) {
        ExerciseGroupKind.single => 'Esercizio eliminato',
        ExerciseGroupKind.superset => 'Super Serie eliminata',
        ExerciseGroupKind.circuit => 'Circuito eliminato',
      });
    } catch (_) {
      _toast('Errore di rete. Riprova.');
    }
    ref.invalidate(ownPlansProvider);
  }

  Future<void> _renamePlan(WorkoutPlan plan) async {
    if (!_canManage) return;
    final controller = TextEditingController(text: plan.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuovo nome scheda:'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Rinomina')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref
        .read(workoutRepositoryProvider)
        .updatePlan(plan.id, {'name': name});
    _toast('Scheda rinominata');
    ref.invalidate(ownPlansProvider);
  }

  Future<void> _fabAction(List<WorkoutPlan> plans) async {
    if (!_canManage) return;
    if (plans.isEmpty) {
      await _createPlanDialog();
      return;
    }
    final plan = plans.firstWhere((p) => p.id == _planId,
        orElse: () => plans.first);
    final days = plan.dayLabels;
    if (days.isEmpty) {
      await addDayToScheda(context, ref, plan);
      return;
    }
    final day = days.contains(_dayLabel) ? _dayLabel! : days.first;
    await showAddToDay(context, ref, plan, day);
  }

  Future<void> _createPlanDialog() async {
    if (!_canManage) return;
    final name = TextEditingController();
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuova scheda'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 100,
              decoration: const InputDecoration(
                  labelText: 'Nome scheda',
                  hintText: 'Es. Scheda Forza, Upper/Lower...'),
            ),
            TextField(
              controller: notes,
              decoration: const InputDecoration(
                  labelText: 'Note (opzionale)',
                  hintText: 'Obiettivi, indicazioni...'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Crea scheda')),
        ],
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty) {
      _toast('Inserisci un nome per la scheda');
      return;
    }
    final session = ref.read(sessionProvider)!;
    try {
      await ref.read(workoutRepositoryProvider).createPlan(
            userId: session.user.id,
            name: name.text.trim(),
            notes: notes.text.trim().isEmpty ? null : notes.text.trim(),
          );
      _toast('Scheda creata!');
      ref.invalidate(ownPlansProvider);
    } catch (e) {
      _toast('Errore creazione: $e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  static const _monthShort = [
    'Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu',
    'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'
  ];
}

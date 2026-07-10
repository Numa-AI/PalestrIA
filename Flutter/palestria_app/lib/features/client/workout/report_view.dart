import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

const _months = [
  'Gennaio',
  'Febbraio',
  'Marzo',
  'Aprile',
  'Maggio',
  'Giugno',
  'Luglio',
  'Agosto',
  'Settembre',
  'Ottobre',
  'Novembre',
  'Dicembre',
];
const _maxGenerations = 3;

class _Tone {
  const _Tone(this.value, this.label, this.icon, this.desc);
  final String value;
  final String label;
  final String icon;
  final String desc;
}

const _tones = [
  _Tone('serious', 'Serio', '🎯', 'Analitico e professionale'),
  _Tone('motivational', 'Motivazionale', '💪', 'Caloroso ed energico'),
  _Tone('ironic', 'Ironico', '😏', 'Umorismo dry'),
];

String _formatYearMonth(String? ym) {
  if (ym == null || !ym.contains('-')) return ym ?? '';
  final parts = ym.split('-');
  final m = int.tryParse(parts[1]) ?? 0;
  return '${m >= 1 && m <= 12 ? _months[m - 1] : parts[1]} ${parts[0]}';
}

/// Vista "Report AI mensile" (port di allenamento-report.js, §9): report del
/// mese precedente, max 3 generazioni/mese (una per tono), consenso GDPR,
/// archivio da `monthly_reports`, dettaglio con narrative markdown.
class ReportView extends ConsumerStatefulWidget {
  const ReportView({super.key});

  @override
  ConsumerState<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends ConsumerState<ReportView> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  String get _availableMonth {
    final now = DateTime.now();
    final prev = DateTime(now.year, now.month - 1, 1);
    return '${prev.year}-${prev.month.toString().padLeft(2, '0')}';
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final uid = ref.read(sessionProvider)?.user.id;
    if (uid == null) return [];
    final rows = await ref
        .read(supabaseProvider)
        .from('monthly_reports')
        .select('id, year_month, tone, narrative, generated_at, status')
        .eq('user_id', uid)
        .eq('status', 'generated')
        .order('year_month', ascending: false);
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slateBg,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const AppLoading();
          }
          if (snap.hasError) {
            // Senza questo ramo un errore di rete finirebbe silenziosamente
            // trattato come "nessun report" (snap.data null → lista vuota).
            return AppErrorRetry(
              message: 'Errore caricamento report.',
              onRetry: _reload,
            );
          }
          if (ref.read(sessionProvider) == null) {
            return const Center(
              child: Text(
                'Devi essere loggato per vedere i report.',
                style: AppText.meta,
              ),
            );
          }
          final reports = snap.data ?? const [];
          final available = _availableMonth;
          final monthReports = reports
              .where((r) => r['year_month'] == available)
              .toList();
          final tonesGenerated = monthReports
              .map((r) => r['tone'] as String?)
              .toSet();
          final used = monthReports.length;
          final remaining = (_maxGenerations - used).clamp(0, _maxGenerations);

          // Archivio per mese.
          final byMonth = <String, List<Map<String, dynamic>>>{};
          for (final r in reports) {
            (byMonth[r['year_month'] as String? ?? ''] ??= []).add(r);
          }
          final months = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                120,
              ),
              children: [
                _hero(available, remaining),
                const SizedBox(height: AppSpacing.lg),
                const Text(
                  'Tono del mese',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    for (final t in _tones) ...[
                      _toneCard(t, tonesGenerated.contains(t.value), () {
                        final existing = monthReports
                            .where((r) => r['tone'] == t.value)
                            .firstOrNull;
                        if (existing != null) {
                          _openDetail(existing);
                        } else {
                          _generate(available, t.value);
                        }
                      }),
                      if (t != _tones.last)
                        const SizedBox(width: AppSpacing.sm),
                    ],
                  ],
                ),
                if (_tones.every((t) => tonesGenerated.contains(t.value)))
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: Text(
                      'Hai usato tutti e $_maxGenerations i toni per ${_formatYearMonth(available)}.',
                      style: AppText.meta,
                    ),
                  ),
                const SizedBox(height: AppSpacing.lg),
                const Text(
                  'Archivio',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (reports.isEmpty)
                  const Text(
                    'Non hai ancora report generati. Scegli un tono qui '
                    'sopra per generare il primo.',
                    style: AppText.meta,
                  )
                else
                  for (final ym in months) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        _formatYearMonth(ym),
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                    for (final r
                        in (byMonth[ym]!..sort(
                          (a, b) => (b['generated_at'] as String? ?? '')
                              .compareTo(a['generated_at'] as String? ?? ''),
                        )))
                      _archiveRow(r),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _hero(String availableMonth, int remaining) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + AppSpacing.md,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        bottom: AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        gradient: AppGradients.workoutHero,
        borderRadius: BorderRadius.all(Radius.circular(18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'REPORT MENSILE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: Color(0xD9C4B5FD),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatYearMonth(availableMonth),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Scegli un tono e genera il report del mese. Ogni tono può '
            'essere usato una sola volta.',
            style: TextStyle(fontSize: 12.5, color: Color(0xCCFFFFFF)),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              const Text(
                'Generazioni',
                style: TextStyle(fontSize: 12, color: Color(0xCCFFFFFF)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: remaining / _maxGenerations,
                    minHeight: 7,
                    backgroundColor: const Color(0x33FFFFFF),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFFC4B5FD)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$remaining / $_maxGenerations',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toneCard(_Tone t, bool done, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            color: done ? AppColors.purpleGlow : Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: AppShadows.card,
            border: Border.all(
              color: done ? cs.primary : AppColors.border,
              width: done ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              Text(t.icon, style: const TextStyle(fontSize: 24)),
              const SizedBox(height: 6),
              Text(
                t.label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                done ? '✓ Generato — apri' : t.desc,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  color: done ? cs.secondary : AppColors.subtle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _archiveRow(Map<String, dynamic> r) {
    final tone = _tones.where((t) => t.value == r['tone']).firstOrNull;
    final date = DateTime.tryParse(r['generated_at'] as String? ?? '');
    return InkWell(
      onTap: () => _openDetail(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Text(tone?.icon ?? '📝', style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tone?.label ?? (r['tone'] as String? ?? '—'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (date != null)
              Text(
                DateFormat('dd/MM/yyyy').format(date),
                style: const TextStyle(fontSize: 12, color: AppColors.subtle),
              ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.subtle),
          ],
        ),
      ),
    );
  }

  // ── Flusso generazione ────────────────────────────────────────────────────
  Future<void> _generate(String yearMonth, String tone) async {
    final client = ref.read(supabaseProvider);
    final uid = ref.read(sessionProvider)?.user.id;
    if (uid == null) {
      AppSnack.error(context, 'Non sei loggato.');
      return;
    }
    // Consenso GDPR.
    final profile = await client
        .from('profiles')
        .select('report_ai_consent')
        .eq('id', uid)
        .maybeSingle();
    final consent = (profile?['report_ai_consent'] as bool?) ?? false;
    if (!consent) {
      final accepted = await _consentDialog(yearMonth);
      if (accepted != true) return;
      try {
        await client.rpc('set_report_ai_consent', params: {'p_consent': true});
      } catch (e) {
        if (!mounted) return;
        AppSnack.error(context, 'Errore nel salvare il consenso: $e');
        return;
      }
    }
    await _startGeneration(yearMonth, tone);
  }

  Future<bool?> _consentDialog(String yearMonth) {
    var checked = false;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Consenso al trattamento AI'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Per generare il report di ${_formatYearMonth(yearMonth)}, '
                  'l\'app analizza i tuoi dati tramite intelligenza artificiale.',
                ),
                const SizedBox(height: 10),
                const Text(
                  'Dati analizzati:',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Text(
                  '• Prenotazioni (sessioni completate, cancellate, aderenza)\n'
                  '• Log di allenamento (esercizi, carichi, ripetizioni)',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Provider AI: Anthropic (Claude). Nessun altro terzo riceve i tuoi dati.',
                ),
                const SizedBox(height: 6),
                const Text(
                  'Conservazione: il report resta nel tuo profilo. Puoi cancellarlo o revocare il consenso in qualsiasi momento.',
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: checked,
                  onChanged: (v) => setLocal(() => checked = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'Acconsento al trattamento AI dei miei dati per generare i report mensili.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () {
                if (!checked) {
                  AppSnack.error(
                    ctx,
                    'Devi spuntare la casella per procedere.',
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Accetta e continua'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startGeneration(
    String yearMonth,
    String tone, {
    bool isRegen = false,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${isRegen ? 'Rigenerazione' : 'Generazione'} in corso...',
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Sto analizzando i tuoi dati e scrivendo il report.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    try {
      final uid = ref.read(sessionProvider)!.user.id;
      final res = await ref
          .read(supabaseProvider)
          .functions
          .invoke(
            'generate-monthly-report',
            body: {
              'user_id': uid,
              'year_month': yearMonth,
              'tone': tone,
              'force_regenerate': true,
            },
          );
      navigator.pop(); // chiude loading
      if (!mounted) return;
      final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
      if (data['success'] != true) {
        if (data['code'] == 'REGEN_LIMIT_REACHED') {
          AppSnack.error(
            context,
            'Hai raggiunto il limite di ${data['limit'] ?? _maxGenerations} generazioni per questo mese. Non puoi rigenerare ulteriormente.',
          );
        } else {
          AppSnack.error(
            context,
            'Errore nella generazione: ${data['error'] ?? 'richiesta fallita'}',
          );
        }
        return;
      }
      _reload();
      // Apre il dettaglio appena ricaricato.
      final reports = await _load();
      final created = reports
          .where((r) => r['id'] == data['report_id'])
          .firstOrNull;
      if (created != null && mounted) _openDetail(created);
    } catch (e) {
      navigator.pop();
      if (!mounted) return;
      AppSnack.error(context, 'Errore: $e');
    }
  }

  // ── Dettaglio report ──────────────────────────────────────────────────────
  void _openDetail(Map<String, dynamic> report) {
    final tone = _tones.where((t) => t.value == report['tone']).firstOrNull;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => Column(
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.borderHover,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Text(
                    _formatYearMonth(report['year_month'] as String?),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${tone?.icon ?? ''} ${tone?.label ?? ''}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 20),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.xxxl,
                ),
                children: _markdownWidgets(
                  (report['narrative'] as String?) ?? '',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Markdown minimale → widget (# ## ### header, **bold**, *italic*, paragrafi).
  List<Widget> _markdownWidgets(String md) {
    final out = <Widget>[];
    for (final block in md.split(RegExp(r'\n{2,}'))) {
      final t = block.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('### ')) {
        out.add(_h(t.substring(4), 15));
      } else if (t.startsWith('## ')) {
        out.add(_h(t.substring(3), 17));
      } else if (t.startsWith('# ')) {
        out.add(_h(t.substring(2), 19));
      } else {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Color(0xFF1F2937),
                ),
                children: _inline(t.replaceAll('\n', ' ')),
              ),
            ),
          ),
        );
      }
    }
    return out;
  }

  Widget _h(String text, double size) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w800,
        color: AppColors.navy,
      ),
    ),
  );

  List<InlineSpan> _inline(String text) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*([^*]+)\*\*|\*([^*]+)\*');
    var i = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > i) spans.add(TextSpan(text: text.substring(i, m.start)));
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      i = m.end;
    }
    if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
    return spans;
  }
}

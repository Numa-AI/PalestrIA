import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/models/workout.dart';

const _accent = PdfColor.fromInt(0xFF8B5CF6);
const _navy = PdfColor.fromInt(0xFF0F172A);
const _gray = PdfColor.fromInt(0xFF64748B);
const _lightGray = PdfColor.fromInt(0xFFE2E8F0);

/// Genera e condivide il PDF della scheda di allenamento (port di
/// `_buildSchedaPDF` / vista PDF §8.9, allenamento.html). A4 portrait, header
/// scheda + note, una barra viola per giorno, per esercizio un badge numerato,
/// target/gruppo/note e una tabella Serie|Reps|Kg|Riposo|Fatto (cardio:
/// Minuti|Fatto) con righe pre-compilate + 1 vuota. Superset/circuito con
/// intestazione dedicata. Le miniature del web (via image-proxy) sono omesse.
///
/// Ritorna l'esito di [Printing.sharePdf]: `false` se l'utente ha annullato
/// il foglio di condivisione (il chiamante può quindi evitare un feedback
/// di successo fuorviante, senza però trattarlo come un errore).
Future<bool> shareWorkoutPdf(WorkoutPlan plan, {String? userName}) async {
  final doc = pw.Document();
  final content = <pw.Widget>[];

  content.add(
    pw.Text(
      plan.name,
      style: pw.TextStyle(
        fontSize: 20,
        fontWeight: pw.FontWeight.bold,
        color: _navy,
      ),
    ),
  );
  if (userName != null && userName.isNotEmpty) {
    content.add(
      pw.Text(userName, style: const pw.TextStyle(fontSize: 11, color: _gray)),
    );
  }
  content.add(
    pw.Text(
      'Data: ____/____/________',
      style: const pw.TextStyle(fontSize: 10, color: _gray),
    ),
  );
  content.add(
    pw.Container(
      height: 1.4,
      color: _accent,
      margin: const pw.EdgeInsets.symmetric(vertical: 7),
    ),
  );
  if ((plan.notes ?? '').trim().isNotEmpty) {
    content.add(
      pw.Text(
        plan.notes!.trim(),
        style: pw.TextStyle(
          fontSize: 10,
          color: _gray,
          fontStyle: pw.FontStyle.italic,
        ),
      ),
    );
  }

  for (final day in plan.dayLabels) {
    final exercises = plan.exercisesOf(day);
    if (exercises.isEmpty) continue;
    content.add(
      pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 12, bottom: 6),
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: pw.BoxDecoration(
          color: _accent,
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Text(
          day.toUpperCase(),
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
        ),
      ),
    );

    var n = 0;
    for (final block in _group(exercises)) {
      if (block.length > 1) {
        final isCircuit = block.first.circuitGroup != null;
        content.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4, bottom: 2),
            child: pw.Text(
              isCircuit ? 'CIRCUITO' : 'SUPER SERIE',
              style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: _accent,
                letterSpacing: 0.5,
              ),
            ),
          ),
        );
      }
      for (final e in block) {
        n++;
        content.add(_exercise(n, e));
      }
    }
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.all(14 * PdfPageFormat.mm),
      footer: (ctx) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 6),
        child: pw.Text(
          'PalestrIA   ·   ${ctx.pageNumber} / ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: _gray),
        ),
      ),
      build: (ctx) => content,
    ),
  );

  final bytes = await doc.save();
  final slug = plan.name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return Printing.sharePdf(
    bytes: bytes,
    filename: 'scheda-${slug.isEmpty ? 'allenamento' : slug}.pdf',
  );
}

/// Raggruppa esercizi consecutivi con lo stesso superset/circuit group.
List<List<WorkoutExercise>> _group(List<WorkoutExercise> exercises) {
  final out = <List<WorkoutExercise>>[];
  String? curKey;
  for (final e in exercises) {
    final key = e.supersetGroup ?? e.circuitGroup;
    if (key != null && key == curKey && out.isNotEmpty) {
      out.last.add(e);
    } else {
      out.add([e]);
      curKey = key;
    }
  }
  return out;
}

pw.Widget _exercise(int n, WorkoutExercise e) {
  final headers = e.isCardio
      ? const ['Minuti', 'Fatto ✓']
      : const ['Serie', 'Reps', 'Kg', 'Riposo', 'Fatto ✓'];
  final weight = (e.weightKg == null || e.weightKg == 0)
      ? ''
      : (e.weightKg! == e.weightKg!.roundToDouble()
            ? e.weightKg!.toStringAsFixed(0)
            : e.weightKg!.toStringAsFixed(1));
  final rest = e.restSeconds <= 0
      ? ''
      : (e.restSeconds <= 3 ? '${e.restSeconds} min' : '${e.restSeconds}s');
  final rows = <List<String>>[];
  if (e.isCardio) {
    rows.add([e.reps, '']);
    rows.add(['', '']);
  } else {
    for (var i = 1; i <= e.sets; i++) {
      rows.add(['$i', e.reps, weight, rest, '']);
    }
    rows.add(['', '', '', '', '']);
  }

  return pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 8),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(
              width: 16,
              height: 16,
              alignment: pw.Alignment.center,
              margin: const pw.EdgeInsets.only(right: 6, top: 1),
              decoration: const pw.BoxDecoration(
                color: _accent,
                shape: pw.BoxShape.circle,
              ),
              child: pw.Text(
                '$n',
                style: pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    e.exerciseName,
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: _navy,
                    ),
                  ),
                  pw.Text(
                    e.targetLabel,
                    style: const pw.TextStyle(fontSize: 9, color: _gray),
                  ),
                  if ((e.muscleGroup ?? '').isNotEmpty)
                    pw.Text(
                      e.muscleGroup!,
                      style: const pw.TextStyle(fontSize: 8, color: _gray),
                    ),
                  if ((e.notes ?? '').trim().isNotEmpty)
                    pw.Text(
                      e.notes!.trim(),
                      style: pw.TextStyle(
                        fontSize: 8,
                        color: _gray,
                        fontStyle: pw.FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headers: headers,
          data: rows,
          headerStyle: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
          headerDecoration: const pw.BoxDecoration(color: _navy),
          cellStyle: const pw.TextStyle(fontSize: 8),
          cellHeight: 16,
          oddRowDecoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFF8FAFC),
          ),
          border: pw.TableBorder.all(color: _lightGray, width: 0.5),
          cellAlignment: pw.Alignment.center,
        ),
      ],
    ),
  );
}

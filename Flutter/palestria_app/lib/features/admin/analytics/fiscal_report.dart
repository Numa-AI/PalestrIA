import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/data/admin_repository.dart';

/// Genera e condivide il **report fiscale** (port di downloadFiscalReport,
/// admin-analytics.js): tutti i pagamenti tracciabili fiscalmente
/// (carta/bonifico/stripe/contanti-report, importo > 0), incrociati con
/// l'anagrafica (CF + indirizzo dai profili), ordinati per data. Il web
/// produce un XLSX; qui un PDF condiviso via `Printing.sharePdf` (share sheet
/// → salva/invia). Ritorna il numero di righe, o lancia in caso d'errore.
Future<int> shareFiscalReport({
  required List<PaymentRow> payments,
  required List<AdminProfile> profiles,
  String? studioName,
}) async {
  const reportMethods = {'carta', 'iban', 'stripe', 'contanti-report'};
  const methodLabel = {
    'carta': 'Carta',
    'iban': 'Bonifico',
    'stripe': 'Stripe',
    'contanti-report': 'Contanti con Report',
  };
  const kindLabel = {
    'session': 'Sessione',
    'membership': 'Abbonamento',
    'package_purchase': 'Pacchetto',
    'penalty_mora': 'Mora',
    'adjustment': 'Rettifica',
  };

  final byEmail = <String, AdminProfile>{
    for (final p in profiles)
      if (p.email.isNotEmpty) p.email.toLowerCase(): p
  };

  final dt = DateFormat('dd/MM/yyyy HH:mm', 'it_IT');

  final filtered = payments
      .where((p) => reportMethods.contains(p.method) && p.amount > 0)
      .toList()
    ..sort((a, b) {
      final ax = a.createdAt?.toIso8601String() ?? '';
      final bx = b.createdAt?.toIso8601String() ?? '';
      return ax.compareTo(bx);
    });

  final data = <List<String>>[];
  for (final p in filtered) {
    final u = byEmail[(p.clientEmail ?? '').toLowerCase()];
    final full = (u?.name ?? p.clientEmail ?? '').trim();
    final parts = full.isEmpty ? <String>[] : full.split(RegExp(r'\s+'));
    final nome = parts.isEmpty ? '' : parts.first;
    final cognome = parts.length <= 1 ? '' : parts.sublist(1).join(' ');
    final addr = [u?.indirizzoVia, u?.indirizzoPaese, u?.indirizzoCap]
        .where((x) => x != null && x.isNotEmpty)
        .join(', ');
    data.add([
      nome,
      cognome,
      u?.codiceFiscale ?? '',
      addr,
      p.createdAt == null ? '' : dt.format(p.createdAt!.toLocal()),
      kindLabel[p.kind] ?? p.kind,
      methodLabel[p.method] ?? p.method,
      _money(p.amount),
    ]);
  }

  final doc = pw.Document();
  final now = DateTime.now();
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => [
        pw.Header(
          level: 0,
          child: pw.Text(
            'Report Fiscale${studioName != null && studioName.isNotEmpty ? ' — $studioName' : ''}',
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
        ),
        pw.Text(
          'Generato il ${DateFormat('dd/MM/yyyy HH:mm', 'it_IT').format(now)} · ${data.length} pagamenti tracciati',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 10),
        if (data.isEmpty)
          pw.Text('Nessun pagamento fiscale nel periodo.',
              style: const pw.TextStyle(fontSize: 11))
        else
          pw.TableHelper.fromTextArray(
            headers: const [
              'Nome',
              'Cognome',
              'Codice Fiscale',
              'Indirizzo',
              'Data e Ora',
              'Tipo',
              'Metodo',
              'Importo (€)'
            ],
            data: data,
            headerStyle:
                pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
            headerDecoration:
                const pw.BoxDecoration(color: PdfColors.grey200),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignment: pw.Alignment.centerLeft,
            cellAlignments: {7: pw.Alignment.centerRight},
            columnWidths: {
              0: const pw.FlexColumnWidth(1.3),
              1: const pw.FlexColumnWidth(1.5),
              2: const pw.FlexColumnWidth(1.8),
              3: const pw.FlexColumnWidth(2.6),
              4: const pw.FlexColumnWidth(1.7),
              5: const pw.FlexColumnWidth(1.2),
              6: const pw.FlexColumnWidth(1.6),
              7: const pw.FlexColumnWidth(1.0),
            },
          ),
      ],
    ),
  );

  final bytes = await doc.save();
  final dateFmt = DateFormat('dd-MM-yyyy').format(now);
  await Printing.sharePdf(
      bytes: bytes, filename: 'PalestrIA_Report_Fiscale_$dateFmt.pdf');
  return data.length;
}

String _money(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

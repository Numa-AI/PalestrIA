import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../client/booking/booking_providers.dart';
import 'client_edit_sheet.dart';

/// Card cliente redesign viola "v2" (spec-admin §6.5-6.8).
class ClientCard extends ConsumerStatefulWidget {
  const ClientCard({super.key, required this.client});

  final AdminClient client;

  @override
  ConsumerState<ClientCard> createState() => _ClientCardState();
}

class _ClientCardState extends ConsumerState<ClientCard> {
  bool _open = false;
  bool _showStorico = false;

  AdminClient get c => widget.client;

  @override
  Widget build(BuildContext context) {
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          left: BorderSide(
              color: _open
                  ? AppColors.primaryDark
                  : AppColors.primary,
              width: 4),
          top: const BorderSide(color: Color(0xFFEEF0F3)),
          right: const BorderSide(color: Color(0xFFEEF0F3)),
          bottom: const BorderSide(color: Color(0xFFEEF0F3)),
        ),
        borderRadius: BorderRadius.circular(AppRadius.cardLg),
        boxShadow: AppShadows.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _header(),
          _statsGrid(),
          if (_open) _body(config),
        ],
      ),
    );
  }

  Widget _header() {
    final initials = _initials(c.name);
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Container(
        color: _open ? const Color(0xFFF5F3FF) : Colors.white,
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: AppSpacing.lg),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _open ? const Color(0xFFDDD6FE) : const Color(0xFFEDE9FE),
                shape: BoxShape.circle,
              ),
              child: Text(initials,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.secondary,
                      fontWeight: FontWeight.w800,
                      fontSize: 15)),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: Color(0xFF1A1A1A))),
                  const SizedBox(height: 3),
                  ..._contacts(),
                  _badgesRow(),
                ],
              ),
            ),
            if (c.profile != null)
              IconButton(
                icon: const Icon(Icons.edit_note, size: 22, color: AppColors.primary),
                tooltip: 'Modifica documenti',
                onPressed: () =>
                    showClientDocsEditSheet(context, ref, c.profile!),
              ),
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.keyboard_arrow_down,
                  color: Color(0xFFAAAAAA)),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _contacts() {
    final widgets = <Widget>[];
    if (c.whatsapp != null && c.whatsapp!.isNotEmpty) {
      final display = c.whatsapp!.replaceFirst(RegExp(r'^\+39\s*'), '');
      widgets.add(_contactLink(Icons.phone_outlined, display, () async {
        final digits = _waNumber(c.whatsapp!);
        await launchUrl(Uri.parse('https://wa.me/$digits'),
            mode: LaunchMode.externalApplication);
      }));
    }
    if (c.email != null && c.email!.isNotEmpty) {
      widgets.add(_contactLink(Icons.mail_outline, c.email!, () async {
        await launchUrl(Uri.parse('mailto:${c.email}'));
      }));
    }
    return widgets;
  }

  Widget _contactLink(IconData icon, String text, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              Icon(icon, size: 14, color: AppColors.subtle),
              const SizedBox(width: 5),
              Flexible(
                child: Text(text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFF475569),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );

  Widget _badgesRow() {
    final p = c.profile;
    if (p == null) return const SizedBox.shrink();
    final badges = <Widget>[];

    // Certificato
    badges.add(_certBadge(
      expiry: p.medicalCertExpiry,
      okText: (d) => '✅ Cert. valido fino al $d',
      expiredText: (d) => '🏥 Cert. scaduto il $d',
      expiringText: (d) => '⏳ Cert. scade il $d',
      missingText: '🏥 Imposta scadenza certificato medico',
    ));
    // Assicurazione
    badges.add(_certBadge(
      expiry: p.insuranceExpiry,
      okText: (d) => '✅ Assicurazione valida fino al $d',
      expiredText: (d) => '📋 Assicurazione scaduta il $d',
      expiringText: (d) => '⏳ Assicurazione scade il $d',
      missingText: '📋 Imposta scadenza assicurazione',
    ));
    // Anagrafica
    if (p.anagraficaIncompleta) {
      badges.add(_badge('📋 Completa anagrafica', _BadgeTone.expiring));
    }
    // Documento
    badges.add(_badge(
        p.documentoFirmato ? '✅ Documento firmato' : '📝 Documento non firmato',
        p.documentoFirmato ? _BadgeTone.ok : _BadgeTone.expired));

    if (badges.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 6, runSpacing: 6, children: badges),
    );
  }

  Widget _certBadge({
    required DateTime? expiry,
    required String Function(String) okText,
    required String Function(String) expiredText,
    required String Function(String) expiringText,
    required String missingText,
  }) {
    if (expiry == null) return _badge(missingText, _BadgeTone.expired);
    final d =
        '${expiry.day.toString().padLeft(2, '0')}/${expiry.month.toString().padLeft(2, '0')}/${expiry.year}';
    final days = expiry.difference(DateTime.now()).inDays;
    if (days < 0) return _badge(expiredText(d), _BadgeTone.expired);
    if (days <= 30) return _badge(expiringText(d), _BadgeTone.expiring);
    return _badge(okText(d), _BadgeTone.ok);
  }

  Widget _badge(String text, _BadgeTone tone) {
    final (bg, fg) = switch (tone) {
      _BadgeTone.expired => (AppColors.docDangerBg, AppColors.docDangerText),
      _BadgeTone.expiring => (AppColors.docWarnBg, AppColors.docWarnText),
      _BadgeTone.ok => (AppColors.docOkBg, AppColors.docOkText),
    };
    return StatusPill(label: text, background: bg, foreground: fg, dense: true);
  }

  Widget _statsGrid() {
    final now = DateTime.now();
    final futureCount = c.bookings
        .where((b) =>
            b.status != 'cancelled' &&
            lessonStart(b.date, b.time).isAfter(now))
        .length;
    // Da saldare: passate, non pagate, non annullate/pending. Prezzo allineato
    // al server e agli altri schermi (bookingPrice: custom ?? default tipo).
    final settings = ref.read(orgSettingsProvider).value;
    final config = ref.read(scheduleConfigProvider).value;
    double unpaid = 0;
    for (final b in c.bookings) {
      if (b.paid ||
          b.status == 'cancelled' ||
          b.status == 'cancellation_requested') {
        continue;
      }
      if (lessonStart(b.date, b.time).isAfter(now)) continue;
      unpaid += bookingPrice(b, settings, config);
    }
    final unpaidStr = unpaid == unpaid.roundToDouble()
        ? unpaid.toStringAsFixed(0)
        : unpaid.toStringAsFixed(2);

    Widget cell(String value, String label, {Color? valueColor}) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                      color: valueColor ?? AppColors.navy,
                      fontFeatures: AppText.tabularNums)),
              const SizedBox(height: 2),
              Text(label.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: unpaid > 0 && label == 'Da saldare'
                          ? AppColors.dangerDark
                          : AppColors.subtle)),
            ],
          ),
        );

    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Container(
        color: _open ? const Color(0xFFF5F3FF) : Colors.white,
        padding:
            const EdgeInsets.fromLTRB(18, AppSpacing.sm, 18, AppSpacing.md),
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(
                  color: _open
                      ? const Color(0xFFEDE9FE)
                      : AppColors.slateBg)),
        ),
        child: Row(
          children: [
            cell('$futureCount', 'Prenot. Future',
                valueColor: AppColors.primary),
            cell('—', 'Sessioni residue'),
            cell('€$unpaidStr', 'Da saldare',
                valueColor: unpaid > 0 ? AppColors.dangerDark : null),
          ],
        ),
      ),
    );
  }

  Widget _body(OrgScheduleConfig config) {
    final bTotal = c.bookings.length;
    final movs = c.bookings
        .where((b) => b.status != 'cancelled' && b.paid)
        .toList()
      ..sort((a, b) {
        final ka = a.paidAt?.toIso8601String() ?? '${a.date}T00:00:00';
        final kb = b.paidAt?.toIso8601String() ?? '${b.date}T00:00:00';
        return kb.compareTo(ka);
      });

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Switch segmentato
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2F6),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              children: [
                _segButton('Prenotazioni · $bTotal', !_showStorico,
                    () => setState(() => _showStorico = false)),
                _segButton('Storico · ${movs.length}', _showStorico,
                    () => setState(() => _showStorico = true)),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (!_showStorico)
            _bookingsPanel(config)
          else
            _storicoPanel(config, movs),
        ],
      ),
    );
  }

  Widget _segButton(String label, bool active, VoidCallback onTap) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: active ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: active
                  ? [
                      const BoxShadow(
                          color: Color(0x1A0F172A),
                          blurRadius: 4,
                          offset: Offset(0, 1)),
                    ]
                  : null,
            ),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: active
                        ? Theme.of(context).colorScheme.secondary
                        : AppColors.muted)),
          ),
        ),
      );

  Widget _bookingsPanel(OrgScheduleConfig config) {
    if (c.bookings.isEmpty) {
      return _emptyPanel('Nessuna prenotazione');
    }
    return Column(
      children: [for (final b in c.bookings) _bookRow(config, b)],
    );
  }

  Widget _bookRow(OrgScheduleConfig config, Booking b) {
    final now = DateTime.now();
    final isFuture = lessonStart(b.date, b.time).isAfter(now);
    final cancelled = b.status == 'cancelled';
    final barColor = cancelled
        ? AppColors.borderGray
        : config.slotColor(b.slotType);
    final d = DateTime.parse(b.date);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: isFuture && !cancelled ? AppColors.dangerSurface : Colors.white,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 3,
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(config.slotName(b.slotType),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: cancelled
                            ? const Color(0xFFB0B6BF)
                            : AppColors.navy,
                        decoration: cancelled
                            ? TextDecoration.lineThrough
                            : null)),
                const SizedBox(height: 2),
                Text('${d.day}/${d.month} · ${b.time}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.subtle)),
              ],
            ),
          ),
          _paymentPill(b),
        ],
      ),
    );
  }

  Widget _paymentPill(Booking b) {
    String text;
    Color bg;
    Color fg;
    if (b.status == 'cancelled') {
      text = '✕ Annullata';
      bg = AppColors.cancelledBg;
      fg = AppColors.cancelledText;
    } else if (b.status == 'cancellation_requested') {
      text = '⏳ Annullamento';
      bg = AppColors.cancelReqBg;
      fg = AppColors.cancelReqText;
    } else if (b.paid &&
        (b.paymentMethod == 'gratuito' ||
            b.paymentMethod == 'lezione-gratuita')) {
      text = '🎁 Gratuita';
      bg = AppColors.cancelledBg;
      fg = AppColors.cancelledText;
    } else if (b.paid) {
      final method = switch (b.paymentMethod) {
        'contanti' => ' con Contanti',
        'contanti-report' => ' con Contanti (report)',
        'carta' => ' con Carta',
        'iban' => ' con Bonifico',
        'stripe' => ' con Stripe',
        _ => '',
      };
      text = '✓ Pagato$method';
      bg = const Color(0x1A22C55E);
      fg = AppColors.success;
    } else {
      text = 'Non pagato';
      bg = const Color(0x1AF59E0B);
      fg = const Color(0xFFD97706);
    }
    return StatusPill(label: text, background: bg, foreground: fg);
  }

  Widget _storicoPanel(OrgScheduleConfig config, List<Booking> movs) {
    if (movs.isEmpty) return _emptyPanel('Nessun incasso registrato');
    return Column(
      children: [
        for (final b in movs) _txRow(config, b),
      ],
    );
  }

  Widget _txRow(OrgScheduleConfig config, Booking b) {
    final free = b.paymentMethod == 'gratuito' ||
        b.paymentMethod == 'lezione-gratuita';
    final price =
        free ? 0.0 : bookingPrice(b, ref.read(orgSettingsProvider).value, config);
    final d = DateTime.parse(b.date);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(9)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 3,
            decoration: BoxDecoration(
              color: free ? AppColors.borderHover : AppColors.green500,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${free ? '🎁' : '💰'} ${config.slotName(b.slotType)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.navy)),
                const SizedBox(height: 2),
                Text('${d.day}/${d.month} · ${b.time}',
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.subtle)),
              ],
            ),
          ),
          Text(
            free
                ? '€0'
                : '+€${price == price.roundToDouble() ? price.toStringAsFixed(0) : price.toStringAsFixed(2)}',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: free ? const Color(0xFF9CA3AF) : AppColors.green700,
                fontFeatures: AppText.tabularNums),
          ),
        ],
      ),
    );
  }

  Widget _emptyPanel(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.subtle,
                fontSize: 13.5,
                fontWeight: FontWeight.w600)),
      );

  static String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts[0][0];
    final second = parts.length > 1 ? parts[1][0] : '';
    return (first + second).toUpperCase();
  }

  static String _waNumber(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0039')) digits = digits.substring(2);
    if (digits.length == 10 && digits.startsWith('3')) digits = '39$digits';
    return digits;
  }
}

enum _BadgeTone { expired, expiring, ok }

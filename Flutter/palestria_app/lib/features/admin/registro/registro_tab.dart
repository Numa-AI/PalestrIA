import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Evento del registro (da una prenotazione).
class RegistroEvent {
  RegistroEvent({
    required this.type,
    required this.timestamp,
    required this.clientName,
    this.slotType = '',
    this.lessonDate = '',
    this.lessonTime = '',
    this.billingKind = 'booking',
    this.amount,
    this.method,
    this.note,
  });
  final String type; // created | paid | cancelled | cancel_req
  final DateTime timestamp;
  final String clientName;
  final String slotType;
  final String lessonDate;
  final String lessonTime;
  final String billingKind;
  final double? amount;
  final String? method;
  final String? note;
}

/// Tab Registro (spec-admin §5): 3 sub-tab — eventi prenotazioni, notifiche
/// admin, notifiche clienti.
class RegistroTab extends ConsumerStatefulWidget {
  const RegistroTab({super.key});

  @override
  ConsumerState<RegistroTab> createState() => _RegistroTabState();
}

class _RegistroTabState extends ConsumerState<RegistroTab> {
  int _sub = 0;
  String _query = '';
  String _range = 'all'; // all | month | year
  String _billingKind = 'all';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _subTabs(),
        Expanded(
          child: switch (_sub) {
            0 => _registroPanel(),
            1 => _adminMessagesPanel(),
            _ => _clientNotifPanel(),
          },
        ),
      ],
    );
  }

  Widget _subTabs() {
    final cs = Theme.of(context).colorScheme;
    Widget tab(String label, int index) {
      final active = _sub == index;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _sub = index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: active ? cs.primary : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: active ? cs.secondary : AppColors.muted,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      child: Row(
        children: [
          tab('Registro', 0),
          tab('Notifiche admin', 1),
          tab('Notifiche clienti', 2),
        ],
      ),
    );
  }

  // ---- Sub-tab 1: Registro eventi ----
  Widget _registroPanel() {
    final bookingsAsync = ref.watch(adminBookingsProvider);
    final auditAsync = ref.watch(adminAuditLogProvider);
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();
    final settings = ref.watch(orgSettingsProvider).value;

    if (auditAsync.isLoading) return const AppLoading();
    if (auditAsync.hasError) {
      return AppErrorRetry(
        message: 'Errore caricamento log economici.',
        onRetry: () => ref.invalidate(adminAuditLogProvider),
      );
    }

    return bookingsAsync.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore caricamento eventi.',
        onRetry: () => ref.invalidate(adminBookingsProvider),
      ),
      data: (bookings) {
        final events = _buildEvents(
          bookings,
          auditAsync.value ?? const [],
          settings,
          config,
        );
        final filtered = _filterEvents(events);
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(adminBookingsProvider);
            ref.invalidate(adminAuditLogProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              100,
            ),
            children: [
              TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  hintText: 'Nome, telefono...',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  _rangeChip('Tutto', 'all'),
                  const SizedBox(width: 6),
                  _rangeChip('Questo mese', 'month'),
                  const SizedBox(width: 6),
                  _rangeChip('Quest\'anno', 'year'),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _billingChip('Tutti i tipi', 'all'),
                    const SizedBox(width: 6),
                    _billingChip('Lezioni / saldo', 'lesson'),
                    const SizedBox(width: 6),
                    _billingChip('Pacchetti', 'package'),
                    const SizedBox(width: 6),
                    _billingChip('Abbonamenti', 'membership'),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (filtered.isEmpty)
                const AppEmptyState(
                  icon: Icons.event_busy_outlined,
                  title: 'Nessun evento trovato con i filtri selezionati.',
                )
              else
                for (final e in filtered) _eventRow(config, e),
            ],
          ),
        );
      },
    );
  }

  Widget _billingChip(String label, String value) => FilterChip(
    selected: _billingKind == value,
    label: Text(label),
    onSelected: (_) => setState(() => _billingKind = value),
  );

  Widget _rangeChip(String label, String value) {
    final active = _range == value;
    return GestureDetector(
      onTap: () => setState(() => _range = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          gradient: active ? brandGradient(context) : null,
          color: active ? null : AppColors.slate50,
          border: Border.all(
            color: active ? Colors.transparent : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }

  List<RegistroEvent> _buildEvents(
    List<Booking> bookings,
    List<Map<String, dynamic>> auditRows,
    OrgSettingsService? settings,
    OrgScheduleConfig config,
  ) {
    final events = <RegistroEvent>[];
    final coveredCreated = <String>{};
    final coveredPaid = <String>{};
    for (final row in auditRows) {
      final action = _auditAction(row);
      if (_auditKind(action) == null) continue;
      final metadata = _metadata(row);
      final bookingId =
          metadata['booking_id']?.toString() ??
          (row['target_type'] == 'booking'
              ? row['target_id']?.toString()
              : null);
      if (bookingId != null &&
          const {
            'lesson_booked',
            'package_lesson_reserved',
            'membership_lesson_used',
            'free_lesson_booked',
          }.contains(action)) {
        coveredCreated.add(bookingId);
        if (action != 'lesson_booked') coveredPaid.add(bookingId);
      }
      if (bookingId != null &&
          const {
            'lesson_payment_recorded',
            'client_payment_recorded',
          }.contains(action)) {
        coveredPaid.add(bookingId);
      }
    }
    for (final b in bookings) {
      final name = b.name ?? '—';
      final amount = bookingPrice(b, settings, config);
      final bookingId = b.sbId ?? b.id;
      if (!coveredCreated.contains(bookingId)) {
        events.add(
          RegistroEvent(
            type: 'created',
            timestamp:
                b.createdAt ??
                DateTime.tryParse('${b.date}T08:00:00') ??
                DateTime.now(),
            clientName: name,
            slotType: b.slotType,
            lessonDate: b.date,
            lessonTime: b.time,
            amount: amount,
          ),
        );
      }
      if (b.paidAt != null && !coveredPaid.contains(bookingId)) {
        events.add(
          RegistroEvent(
            type: 'paid',
            timestamp: b.paidAt!,
            clientName: name,
            slotType: b.slotType,
            lessonDate: b.date,
            lessonTime: b.time,
            amount: amount,
            method: b.paymentMethod,
          ),
        );
      }
      if (b.cancellationRequestedAt != null) {
        events.add(
          RegistroEvent(
            type: 'cancel_req',
            timestamp: b.cancellationRequestedAt!,
            clientName: name,
            slotType: b.slotType,
            lessonDate: b.date,
            lessonTime: b.time,
          ),
        );
      }
      if (b.status == 'cancelled' && b.cancelledAt != null) {
        events.add(
          RegistroEvent(
            type: 'cancelled',
            timestamp: b.cancelledAt!,
            clientName: name,
            slotType: b.slotType,
            lessonDate: b.date,
            lessonTime: b.time,
          ),
        );
      }
    }

    for (final row in auditRows) {
      final action = _auditAction(row);
      final kind = _auditKind(action);
      if (kind == null) continue;
      final metadata = _metadata(row);
      events.add(
        RegistroEvent(
          type: action,
          timestamp:
              DateTime.tryParse(row['created_at']?.toString() ?? '') ??
              DateTime.now(),
          clientName:
              metadata['client_name']?.toString() ??
              metadata['client_email']?.toString() ??
              'Cliente',
          slotType: metadata['slot_type']?.toString() ?? '',
          lessonDate: metadata['lesson_date']?.toString() ?? '',
          lessonTime: metadata['lesson_time']?.toString() ?? '',
          billingKind: kind,
          amount: (metadata['amount'] as num?)?.toDouble(),
          method:
              metadata['payment_method']?.toString() ??
              metadata['method']?.toString(),
          note: metadata['note']?.toString(),
        ),
      );
    }
    events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return events;
  }

  List<RegistroEvent> _filterEvents(List<RegistroEvent> events) {
    final now = DateTime.now();
    final q = _query.trim().toLowerCase();
    return events.where((e) {
      if (_range == 'month' &&
          (e.timestamp.year != now.year || e.timestamp.month != now.month)) {
        return false;
      }
      if (_range == 'year' && e.timestamp.year != now.year) return false;
      if (_billingKind != 'all' && e.billingKind != _billingKind) return false;
      if (q.isNotEmpty && !e.clientName.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  Widget _eventRow(OrgScheduleConfig config, RegistroEvent e) {
    final (label, bg, fg, emoji) = _eventStyle(e.type);
    final ts = e.timestamp;
    final tsStr =
        '${ts.day.toString().padLeft(2, '0')}/${ts.month.toString().padLeft(2, '0')} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';

    return AppCard(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          StatusPill(
            label: '$emoji $label',
            background: bg,
            foreground: fg,
            dense: true,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.clientName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                Text(
                  e.slotType.isEmpty
                      ? tsStr
                      : '$tsStr · ${config.slotName(e.slotType)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.subtle,
                  ),
                ),
                if (e.lessonDate.isNotEmpty)
                  Text(
                    'Lezione ${_fmtLessonDate(e.lessonDate)} · ${e.lessonTime}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.subtle,
                    ),
                  ),
                if (e.note != null && e.note!.isNotEmpty)
                  Text(
                    e.note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.subtle,
                    ),
                  ),
              ],
            ),
          ),
          if (_isPaymentEvent(e.type) && e.amount != null)
            Text(
              '+€${_fmt(e.amount!)}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.paidText,
              ),
            )
          else if (e.type == 'created' && e.amount != null)
            Text(
              '€${_fmt(e.amount!)}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.muted,
              ),
            ),
          if (e.type != 'created' &&
              !_isPaymentEvent(e.type) &&
              e.amount != null)
            Text(
              '${e.amount! >= 0 ? '+' : '-'}€${_fmt(e.amount!.abs())}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: e.amount! >= 0
                    ? AppColors.paidText
                    : AppColors.dangerDark,
              ),
            ),
        ],
      ),
    );
  }

  // ---- Sub-tab 2: Notifiche admin ----
  Widget _adminMessagesPanel() {
    final async = ref.watch(adminMessagesProvider);
    return async.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore caricamento messaggi.',
        onRetry: () => ref.invalidate(adminMessagesProvider),
      ),
      data: (msgs) {
        if (msgs.isEmpty) {
          return const AppEmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'Nessun messaggio trovato',
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(adminMessagesProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              100,
            ),
            children: [
              for (final m in msgs)
                _notifCard(
                  title:
                      (m['title'] as String?) ?? _adminMsgTypeLabel(m['type']),
                  subtitle: _adminMsgTypeLabel(m['type']),
                  client: m['client_name'] as String?,
                  createdAt: m['created_at'],
                  sent:
                      (m['sent_count'] as num?) != null &&
                      (m['sent_count'] as num) > 0,
                  sentCount: (m['sent_count'] as num?)?.toInt(),
                ),
            ],
          ),
        );
      },
    );
  }

  // ---- Sub-tab 3: Notifiche clienti ----
  Widget _clientNotifPanel() {
    final async = ref.watch(clientNotificationsProvider);
    return async.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore caricamento notifiche.',
        onRetry: () => ref.invalidate(clientNotificationsProvider),
      ),
      data: (notifs) {
        if (notifs.isEmpty) {
          return const AppEmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'Nessuna notifica trovata',
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(clientNotificationsProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              100,
            ),
            children: [
              for (final n in notifs)
                _notifCard(
                  title: (n['title'] as String?) ?? _cnTypeLabel(n['type']),
                  subtitle: _cnTypeLabel(n['type']),
                  client:
                      n['user_name'] as String? ?? n['user_email'] as String?,
                  createdAt: n['created_at'],
                  sent: n['status'] == 'sent',
                  statusText: _cnStatusLabel(n['status']),
                  status: n['status'],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _notifCard({
    required String title,
    required String subtitle,
    String? client,
    Object? createdAt,
    required bool sent,
    int? sentCount,
    String? statusText,
    Object? status,
  }) {
    final ts = createdAt == null
        ? null
        : DateTime.tryParse(createdAt.toString());
    final tsStr = ts == null
        ? ''
        : '${ts.day.toString().padLeft(2, '0')}/${ts.month.toString().padLeft(2, '0')} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
    // Terzo tono ambra per gli stati "in sospeso" (es. no_subscription), da
    // non confondere con un invio realmente fallito (rosso).
    final (pillBg, pillFg) = sent
        ? (AppColors.successSurface, AppColors.green700)
        : status == 'no_subscription'
        ? (AppColors.warnSurface, AppColors.docWarnText)
        : (AppColors.dangerSurface, AppColors.docDangerText);
    final pillLabel =
        statusText ??
        (sent
            ? '✅ Inviata${sentCount != null ? ' ($sentCount)' : ''}'
            : '❌ Non inviata');
    return AppCard(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                Text(
                  '$subtitle${client != null ? ' · $client' : ''}${tsStr.isNotEmpty ? ' · $tsStr' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.subtle,
                  ),
                ),
              ],
            ),
          ),
          StatusPill(
            label: pillLabel,
            background: pillBg,
            foreground: pillFg,
            dense: true,
          ),
        ],
      ),
    );
  }

  static String _adminMsgTypeLabel(Object? t) => switch (t) {
    'booking' => '✔️ Prenotazione',
    'cancellation' => '❌ Annullamento',
    'new_client' => '🆕 Nuovo iscritto',
    'broadcast' => '📢 Broadcast',
    'proximity' => '📍 Arrivo',
    _ => '📩 Notifica',
  };

  static String _cnTypeLabel(Object? t) => switch (t) {
    'reminder_24h' => '⏰ Promemoria 24h',
    'reminder_1h' => '⏰ Promemoria 1h',
    'slot_available' => '🟢 Slot disponibile',
    'broadcast' => '📢 Broadcast',
    _ => '📬 Notifica',
  };

  static String _cnStatusLabel(Object? s) => switch (s) {
    'sent' => '✅ Inviata',
    'failed' => '❌ Fallita',
    'no_subscription' => '⚠️ No sub',
    _ => '—',
  };

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  /// `YYYY-MM-DD` → `D/M`, coerente con la formattazione date già usata
  /// altrove nell'admin (es. `analytics_tab._bookingRow`).
  static String _fmtLessonDate(String iso) {
    final parts = iso.split('-');
    if (parts.length != 3) return iso;
    final d = int.tryParse(parts[2]);
    final m = int.tryParse(parts[1]);
    if (d == null || m == null) return iso;
    return '$d/$m';
  }

  static Map<String, dynamic> _metadata(Map<String, dynamic> row) =>
      (row['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};

  static String _auditAction(Map<String, dynamic> row) {
    final action = row['action'] as String? ?? '';
    if (action != 'stripe_client_payment') return action;
    return switch (_metadata(row)['kind']) {
      'package_purchase' => 'package_payment_recorded',
      'membership' => 'membership_payment_recorded',
      _ => 'lesson_payment_recorded',
    };
  }

  static String? _auditKind(String action) {
    if (action.startsWith('package_')) return 'package';
    if (action.startsWith('membership_')) return 'membership';
    if (const {
      'lesson_booked',
      'lesson_charge_applied',
      'lesson_charge_reversed',
      'lesson_payment_recorded',
      'lesson_waived',
      'lesson_waiver_reversed',
      'client_credit_added',
      'client_debt_added',
      'client_payment_recorded',
      'client_balance_reset',
      'free_lesson_booked',
    }.contains(action)) {
      return 'lesson';
    }
    return null;
  }

  static bool _isPaymentEvent(String type) => const {
    'paid',
    'lesson_payment_recorded',
    'client_payment_recorded',
    'package_sold',
    'package_payment_recorded',
    'membership_sold',
    'membership_payment_recorded',
  }.contains(type);

  static (String, Color, Color, String) _eventStyle(String type) =>
      switch (type) {
        'created' => (
          'Prenotazione',
          AppColors.infoSurface,
          AppColors.blue600,
          '📅',
        ),
        'paid' => ('Pagamento', AppColors.paidBg, AppColors.paidText, '✅'),
        'cancelled' => (
          'Annullamento',
          AppColors.cancelledBg,
          AppColors.cancelledText,
          '❌',
        ),
        'cancel_req' => (
          'Rich. Annullamento',
          AppColors.warnSurface,
          AppColors.docWarnText,
          '⏳',
        ),
        'lesson_booked' => (
          'Lezione a entrata',
          AppColors.infoSurface,
          AppColors.blue600,
          '📅',
        ),
        'lesson_charge_applied' => (
          'Addebito lezione',
          AppColors.warnSurface,
          AppColors.docWarnText,
          '➖',
        ),
        'lesson_charge_reversed' => (
          'Storno lezione',
          AppColors.paidBg,
          AppColors.paidText,
          '↩️',
        ),
        'lesson_payment_recorded' || 'client_payment_recorded' => (
          'Incasso saldo',
          AppColors.paidBg,
          AppColors.paidText,
          '💶',
        ),
        'client_credit_added' => (
          'Credito aggiunto',
          AppColors.paidBg,
          AppColors.paidText,
          '⬆️',
        ),
        'client_debt_added' => (
          'Debito aggiunto',
          AppColors.warnSurface,
          AppColors.docWarnText,
          '⬇️',
        ),
        'client_balance_reset' => (
          'Saldo annullato',
          AppColors.cancelledBg,
          AppColors.cancelledText,
          '🧹',
        ),
        'lesson_waived' => (
          'Lezione abbuonata',
          AppColors.paidBg,
          AppColors.paidText,
          '🎁',
        ),
        'lesson_waiver_reversed' => (
          'Revoca abbuono',
          AppColors.warnSurface,
          AppColors.docWarnText,
          '↩️',
        ),
        'package_sold' => (
          'Pacchetto venduto',
          AppColors.paidBg,
          AppColors.paidText,
          '🎟️',
        ),
        'package_payment_recorded' => (
          'Pacchetto incassato',
          AppColors.paidBg,
          AppColors.paidText,
          '🎟️',
        ),
        'package_lesson_reserved' => (
          'Ingresso riservato',
          AppColors.infoSurface,
          AppColors.blue600,
          '🔒',
        ),
        'package_lesson_consumed' => (
          'Ingresso scalato',
          AppColors.paidBg,
          AppColors.paidText,
          '🎫',
        ),
        'package_reservation_released' => (
          'Riserva liberata',
          AppColors.cancelledBg,
          AppColors.cancelledText,
          '🔓',
        ),
        'package_lesson_restored' => (
          'Ingresso restituito',
          AppColors.paidBg,
          AppColors.paidText,
          '↩️',
        ),
        'package_cancelled' => (
          'Pacchetto annullato',
          AppColors.cancelledBg,
          AppColors.cancelledText,
          '❌',
        ),
        'membership_sold' || 'membership_payment_recorded' => (
          'Abbonamento incassato',
          AppColors.paidBg,
          AppColors.paidText,
          '🪪',
        ),
        'membership_lesson_used' => (
          'Lezione in abbonamento',
          AppColors.infoSurface,
          AppColors.blue600,
          '✅',
        ),
        'membership_lesson_restored' => (
          'Quota restituita',
          AppColors.paidBg,
          AppColors.paidText,
          '↩️',
        ),
        'membership_cancelled' => (
          'Abbonamento annullato',
          AppColors.cancelledBg,
          AppColors.cancelledText,
          '❌',
        ),
        'free_lesson_booked' => (
          'Lezione gratuita',
          AppColors.infoSurface,
          AppColors.blue600,
          '🎁',
        ),
        _ => ('Evento', AppColors.slate50, AppColors.muted, '•'),
      };
}

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
    required this.slotType,
    required this.lessonDate,
    required this.lessonTime,
    this.amount,
    this.method,
  });
  final String type; // created | paid | cancelled | cancel_req
  final DateTime timestamp;
  final String clientName;
  final String slotType;
  final String lessonDate;
  final String lessonTime;
  final double? amount;
  final String? method;
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
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active ? cs.secondary : AppColors.muted)),
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
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();
    final settings = ref.watch(orgSettingsProvider).value;

    return bookingsAsync.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore caricamento eventi.',
        onRetry: () => ref.invalidate(adminBookingsProvider),
      ),
      data: (bookings) {
        final events = _buildEvents(bookings, settings, config);
        final filtered = _filterEvents(events);
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(adminBookingsProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
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
              color: active ? Colors.transparent : AppColors.border),
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : const Color(0xFF475569))),
      ),
    );
  }

  List<RegistroEvent> _buildEvents(
    List<Booking> bookings,
    OrgSettingsService? settings,
    OrgScheduleConfig config,
  ) {
    final events = <RegistroEvent>[];
    for (final b in bookings) {
      final name = b.name ?? '—';
      final amount = bookingPrice(b, settings, config);
      events.add(RegistroEvent(
        type: 'created',
        timestamp: b.createdAt ?? DateTime.tryParse('${b.date}T08:00:00') ??
            DateTime.now(),
        clientName: name,
        slotType: b.slotType,
        lessonDate: b.date,
        lessonTime: b.time,
        amount: amount,
      ));
      if (b.paidAt != null) {
        events.add(RegistroEvent(
          type: 'paid',
          timestamp: b.paidAt!,
          clientName: name,
          slotType: b.slotType,
          lessonDate: b.date,
          lessonTime: b.time,
          amount: amount,
          method: b.paymentMethod,
        ));
      }
      if (b.cancellationRequestedAt != null) {
        events.add(RegistroEvent(
          type: 'cancel_req',
          timestamp: b.cancellationRequestedAt!,
          clientName: name,
          slotType: b.slotType,
          lessonDate: b.date,
          lessonTime: b.time,
        ));
      }
      if (b.status == 'cancelled' && b.cancelledAt != null) {
        events.add(RegistroEvent(
          type: 'cancelled',
          timestamp: b.cancelledAt!,
          clientName: name,
          slotType: b.slotType,
          lessonDate: b.date,
          lessonTime: b.time,
        ));
      }
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
      if (q.isNotEmpty && !e.clientName.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  Widget _eventRow(OrgScheduleConfig config, RegistroEvent e) {
    final (label, bg, fg, emoji) = switch (e.type) {
      'created' => ('Prenotazione', AppColors.infoSurface, AppColors.blue600,
          '📅'),
      'paid' => ('Pagamento', AppColors.paidBg, AppColors.paidText, '✅'),
      'cancelled' => ('Annullamento', AppColors.cancelledBg,
          AppColors.cancelledText, '❌'),
      _ => ('Rich. Annullamento', AppColors.warnSurface,
          AppColors.docWarnText, '⏳'),
    };
    final ts = e.timestamp;
    final tsStr =
        '${ts.day.toString().padLeft(2, '0')}/${ts.month.toString().padLeft(2, '0')} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';

    return AppCard(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          StatusPill(
              label: '$emoji $label', background: bg, foreground: fg,
              dense: true),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.clientName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13.5)),
                Text('$tsStr · ${config.slotName(e.slotType)}',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.subtle)),
                Text('Lezione ${_fmtLessonDate(e.lessonDate)} · ${e.lessonTime}',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.subtle)),
              ],
            ),
          ),
          if (e.type == 'paid' && e.amount != null)
            Text('+€${_fmt(e.amount!)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: AppColors.paidText))
          else if (e.type == 'created' && e.amount != null)
            Text('€${_fmt(e.amount!)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: AppColors.muted)),
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
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
            children: [
              for (final m in msgs) _notifCard(
                title: (m['title'] as String?) ?? _adminMsgTypeLabel(m['type']),
                subtitle: _adminMsgTypeLabel(m['type']),
                client: m['client_name'] as String?,
                createdAt: m['created_at'],
                sent: (m['sent_count'] as num?) != null &&
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
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
            children: [
              for (final n in notifs)
                _notifCard(
                  title: (n['title'] as String?) ?? _cnTypeLabel(n['type']),
                  subtitle: _cnTypeLabel(n['type']),
                  client: n['user_name'] as String? ?? n['user_email'] as String?,
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
    final ts = createdAt == null ? null : DateTime.tryParse(createdAt.toString());
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
    final pillLabel = statusText ??
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
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13.5)),
                Text(
                    '$subtitle${client != null ? ' · $client' : ''}${tsStr.isNotEmpty ? ' · $tsStr' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 11.5, color: AppColors.subtle)),
              ],
            ),
          ),
          StatusPill(
              label: pillLabel, background: pillBg, foreground: pillFg,
              dense: true),
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
}

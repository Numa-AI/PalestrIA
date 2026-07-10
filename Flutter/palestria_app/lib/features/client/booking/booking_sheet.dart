import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/normalize.dart';
import '../../../core/data/booking_repository.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/models/user_profile.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import 'booking_providers.dart';

/// Bottom sheet di prenotazione (port del #bookingModal, §5 spec-client).
Future<void> showBookingSheet(
    BuildContext context, WidgetRef ref, DaySlot slot) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _BookingSheet(slot: slot),
  );
}

class _BookingSheet extends ConsumerStatefulWidget {
  const _BookingSheet({required this.slot});

  final DaySlot slot;

  @override
  ConsumerState<_BookingSheet> createState() => _BookingSheetState();
}

class _BookingSheetState extends ConsumerState<_BookingSheet> {
  final _notes = TextEditingController();
  bool _submitting = false;
  Booking? _confirmed;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  DaySlot get slot => widget.slot;

  Future<void> _submit() async {
    if (_submitting) return;

    // Cutoff client-side (il server rifà il check).
    if (DateTime.now().isAfter(
        lessonStart(slot.date, slot.time).add(const Duration(minutes: 30)))) {
      _toast(
          'Non è possibile prenotare: sono passati più di 30 minuti dall\'inizio della lezione.');
      if (mounted) Navigator.pop(context);
      return;
    }

    final session = ref.read(sessionProvider);
    if (session == null) {
      _toast('Sessione scaduta: accedi di nuovo per prenotare.');
      return;
    }
    // Il profilo può essere ancora in caricamento (AsyncLoading → value null):
    // attendiamo il primo valore invece di scambiarlo per "anagrafica assente".
    UserProfile? profile = ref.read(userProfileProvider).value;
    if (profile == null) {
      try {
        profile = await ref
            .read(userProfileProvider.future)
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        profile = null;
      }
    }
    if (!mounted) return;
    if (profile == null) {
      _toast('Completa l\'anagrafica prima di prenotare.');
      return;
    }
    final loadedProfile = profile;

    setState(() => _submitting = true);
    final client = ref.read(supabaseProvider);

    // Check duplicato (come il web, query diretta con timeout 10 s).
    // Escludiamo SOLO 'cancelled': una prenotazione 'cancellation_requested'
    // occupa ancora il posto (come Booking.isOccupying e il conteggio di
    // book_slot), quindi va trattata come duplicato e non lasciata riprenotare.
    try {
      final dup = await client
          .from('bookings')
          .select('id')
          .eq('user_id', session.user.id)
          .eq('date', slot.date)
          .eq('time', slot.time)
          .not('status', 'in', '(cancelled)')
          .limit(1)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (dup.isNotEmpty) {
        _toast('Hai già una prenotazione per questo orario.');
        setState(() => _submitting = false);
        return;
      }
    } catch (_) {
      // fail-open: ci pensa il vincolo server (duplicate_booking)
    }
    if (!mounted) return;

    final repo = await ref.read(bookingRepositoryProvider.future);
    final day = parseYmd(slot.date);
    final result = await repo.book(
      date: slot.date,
      time: slot.time,
      name: capitalizeName(loadedProfile.name),
      email: loadedProfile.email.toLowerCase(),
      whatsapp: loadedProfile.whatsapp == null
          ? ''
          : normalizePhone(loadedProfile.whatsapp!),
      notes: _notes.text.trim(),
      dateDisplay: dateDisplayOf(day),
    );

    if (!mounted) return;
    setState(() => _submitting = false);

    if (!result.ok) {
      if (result.errorCode == 'slot_full') {
        _toast(
            'Slot non più disponibile. Qualcun altro ha prenotato prima di te.');
        ref.invalidate(availabilityProvider);
        Navigator.pop(context);
      } else if (result.errorCode == 'too_late') {
        _toast(result.error!);
        Navigator.pop(context);
      } else {
        // Esito incerto/offline: la prenotazione POTREBBE essere andata a
        // buon fine lato server → aggiorna disponibilità e "le mie
        // prenotazioni" così l'utente vede l'eventuale riga e non ritenta
        // alla cieca (il dup-check ora blocca il doppio invio).
        ref.invalidate(availabilityProvider);
        ref.invalidate(ownBookingsProvider);
        _toast(result.error ??
            'Errore durante la prenotazione. Riprova tra qualche secondo.');
      }
      return;
    }

    ref.invalidate(availabilityProvider);
    ref.invalidate(ownBookingsProvider);
    setState(() {
      _confirmed = Booking(
        id: result.bookingId ?? '',
        date: slot.date,
        time: slot.time,
        slotType: slot.slotType,
        dateDisplay: dateDisplayOf(day),
        name: loadedProfile.name,
        paid: result.paid,
      );
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openGoogleCalendar(
      Booking booking, OrgScheduleConfig config) async {
    final start = lessonStart(booking.date, booking.time);
    final endHm = booking.time.split(' - ').last.split(':');
    final end = DateTime(start.year, start.month, start.day,
        int.parse(endHm[0]), int.parse(endHm[1]));
    String fmt(DateTime d) =>
        '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}'
        'T${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}00';
    final typeName = config.slotName(booking.slotType);
    // Fuso configurabile per-org (locale.timezone), come il web; fallback Roma.
    final tz = ref
            .read(orgSettingsProvider)
            .value
            ?.getString('locale.timezone', 'Europe/Rome') ??
        'Europe/Rome';
    final url = Uri.parse('https://calendar.google.com/calendar/render'
        '?action=TEMPLATE'
        '&text=${Uri.encodeComponent('Allenamento – $typeName')}'
        '&dates=${fmt(start)}/${fmt(end)}'
        '&details=${Uri.encodeComponent('Prenotato da ${booking.name ?? ''}')}'
        '&ctz=${Uri.encodeComponent(tz)}');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(scheduleConfigProvider);
    final config = configAsync.value ?? OrgScheduleConfig.empty();
    final color = config.slotColor(slot.slotType);
    final typeName = config.slotName(slot.slotType);
    final day = parseYmd(slot.date);

    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xl),
          child: _confirmed != null
              ? _confirmationView(_confirmed!, config)
              : _formView(color, typeName, day),
        ),
      ),
    );
  }

  Widget _formView(Color color, String typeName, DateTime day) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header slot
        Column(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                typeName.toUpperCase(),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              slot.isFull
                  ? 'Completo'
                  : '${slot.remaining} disponibil${slot.remaining == 1 ? 'e' : 'i'}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: spotsColor(slot.remaining),
              ),
            ),
            const SizedBox(height: 4),
            Text(dateDisplayOf(day),
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700)),
            Text('🕐 ${slot.time}',
                style: const TextStyle(
                    fontSize: 19, fontFeatures: AppText.tabularNums)),
            const SizedBox(height: AppSpacing.md),
            const Divider(),
          ],
        ),
        _attendeesSection(),
        const SizedBox(height: AppSpacing.md),
        if (slot.isFull && !slot.enrolled)
          const SizedBox.shrink()
        else ...[
          TextField(
            controller: _notes,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Note (opzionale)',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(_submitting
                ? 'Prenotazione in corso...'
                : 'Conferma Prenotazione'),
          ),
        ],
      ],
    );
  }

  Widget _attendeesSection() {
    final profile = ref.watch(userProfileProvider).value;
    final privacyOn = profile?.privacyPrenotazioni ?? true;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: slot.isFull,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        backgroundColor: AppColors.slate50,
        collapsedBackgroundColor: AppColors.slate50,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        collapsedShape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        title: const Text('Persone iscritte',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        children: [
          if (privacyOn)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Disattiva la privacy per vedere chi è iscritto.',
                style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: AppColors.subtle,
                    fontSize: 13.5),
              ),
            )
          else
            _AttendeesList(slot: slot),
        ],
      ),
    );
  }

  Widget _confirmationView(Booking booking, OrgScheduleConfig config) {
    final typeName = config.slotName(booking.slotType);
    final branding = Theme.of(context).colorScheme.primary;

    Widget rule(String emoji, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                        fontSize: 13, color: Colors.white, height: 1.45),
                    children: [
                      TextSpan(
                          text: '$title — ',
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(text: body),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [branding, AppColors.primaryDark],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('✓ $typeName Confermata!',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: AppSpacing.sm),
          Text(booking.name ?? '',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, color: Colors.white)),
          Text('📅 ${booking.dateDisplay} · 🕐 ${booking.time}',
              style: const TextStyle(color: Colors.white, fontSize: 14)),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton(
            onPressed: () => _openGoogleCalendar(booking, config),
            style: OutlinedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppText.label.color,
              side: BorderSide.none,
            ),
            child: const Text('Google Calendar'),
          ),
          const SizedBox(height: AppSpacing.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                rule('👟', 'Abbigliamento adeguato',
                    'Indossa scarpe di ricambio pulite (da usare solo in palestra). In alternativa, puoi allenarti con calze antiscivolo. Porta sempre una salvietta personale da usare sugli attrezzi.'),
                rule('🚫', 'Alimentazione e digestione',
                    'Non mangiare nelle 2–3 ore prima dell\'allenamento per evitare fastidi durante l\'attività fisica.'),
                rule('💧', 'Idratazione',
                    'Porta sempre con te una borraccia d\'acqua per mantenerti idratato durante la sessione.'),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            style: OutlinedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: branding,
              side: BorderSide(color: branding, width: 2),
            ),
            child: const Text('← Torna al calendario'),
          ),
        ],
      ),
    );
  }
}

/// Lista iscritti con raggruppamento per tipo (RPC get_slot_attendees).
class _AttendeesList extends ConsumerWidget {
  const _AttendeesList({required this.slot});

  final DaySlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attendeesAsync = ref.watch(_attendeesProvider((slot.date, slot.time)));
    final config = ref.watch(scheduleConfigProvider).value ??
        OrgScheduleConfig.empty();

    return attendeesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: Text('Caricamento...',
            style: TextStyle(
                fontStyle: FontStyle.italic, color: AppColors.subtle)),
      ),
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Expanded(
                child: Text('Impossibile caricare gli iscritti.',
                    style: TextStyle(color: AppColors.subtle))),
            TextButton(
              onPressed: () =>
                  ref.invalidate(_attendeesProvider((slot.date, slot.time))),
              child: const Text('Riprova'),
            ),
          ],
        ),
      ),
      data: (attendees) {
        if (attendees.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nessuna persona visibile per questo slot.',
                style: TextStyle(color: Color(0xFF6B7280), fontSize: 13.5)),
          );
        }
        final types = attendees.map((a) => a.slotType).toSet();
        if (types.length <= 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in attendees)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('👤 ${a.name}',
                        style: const TextStyle(fontSize: 14)),
                  ),
              ],
            ),
          );
        }
        // 2+ tipi: gruppi con pallino colorato + "<NomeTipo> · <conteggio>"
        final byType = <String, List<SlotAttendee>>{};
        for (final a in attendees) {
          byType.putIfAbsent(a.slotType, () => []).add(a);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in byType.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: config.slotColor(entry.key),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${config.slotName(entry.key).toUpperCase()} · ${entry.value.length}',
                        style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF6B7280),
                            letterSpacing: 0.4),
                      ),
                    ],
                  ),
                ),
                for (final a in entry.value)
                  Padding(
                    padding: const EdgeInsets.only(left: 14, top: 2),
                    child:
                        Text('👤 ${a.name}', style: const TextStyle(fontSize: 14)),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

final _attendeesProvider = FutureProvider.autoDispose
    .family<List<SlotAttendee>, (String, String)>((ref, key) async {
  final repo = await ref.watch(bookingRepositoryProvider.future);
  return repo
      .slotAttendees(key.$1, key.$2)
      .timeout(const Duration(seconds: 8));
});

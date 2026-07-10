import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../client/booking/booking_providers.dart';
import 'payments_tab.dart';

/// Popup "Segna come pagato" (spec-admin §7.5): lista lezioni non pagate del
/// contatto (passate + future), metodo, conferma → admin_pay_bookings.
Future<bool?> showPayDebtSheet(
    BuildContext context, WidgetRef ref, DebtorContact contact) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PayDebtSheet(contact: contact),
  );
}

const _methods = [
  ('contanti', '💵 Contanti'),
  ('contanti-report', '🧾 Contanti con Report'),
  ('carta', '💳 Carta'),
  ('iban', '🏦 Bonifico'),
  ('lezione-gratuita', '🎁 Gratuita'),
];

class _PayDebtSheet extends ConsumerStatefulWidget {
  const _PayDebtSheet({required this.contact});
  final DebtorContact contact;

  @override
  ConsumerState<_PayDebtSheet> createState() => _PayDebtSheetState();
}

class _PayDebtSheetState extends ConsumerState<_PayDebtSheet> {
  final Set<String> _selected = {};
  String? _method;
  bool _paying = false;

  @override
  void initState() {
    super.initState();
    // Di default seleziona tutte le passate (hanno sbId).
    for (final b in widget.contact.bookings) {
      if (b.sbId != null) _selected.add(b.sbId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();
    final settings = ref.watch(orgSettingsProvider).value;
    final bookings = widget.contact.bookings
        .where((b) => b.sbId != null)
        .toList()
      ..sort((a, b) => '${a.date}${a.time}'.compareTo('${b.date}${b.time}'));
    final allIds = [for (final b in bookings) b.sbId!];
    final allSelected = allIds.isNotEmpty && allIds.every(_selected.contains);

    // Prezzo allineato al server (admin_pay_bookings) e a payments/analytics.
    final total = bookings
        .where((b) => _selected.contains(b.sbId))
        .fold<double>(0, (s, b) => s + bookingPrice(b, settings, config));

    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.contact.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                      bookings.length == 1
                          ? '1 lezione non pagata'
                          : '${bookings.length} lezioni non pagate',
                      style: AppText.meta),
                  TextButton(
                    onPressed: allIds.isEmpty
                        ? null
                        : () => setState(() {
                              if (allSelected) {
                                _selected.removeAll(allIds);
                              } else {
                                _selected.addAll(allIds);
                              }
                            }),
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: Text(
                        allSelected ? 'Deseleziona tutto' : 'Seleziona tutto',
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final b in bookings) _row(config, settings, b),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration:
                    const InputDecoration(labelText: 'Metodo di pagamento'),
                hint: const Text('Seleziona…'),
                items: [
                  for (final (v, l) in _methods)
                    DropdownMenuItem(value: v, child: Text(l)),
                ],
                onChanged: (v) => setState(() => _method = v),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Dovuto: €${formatEuro(total)}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  FilledButton(
                    onPressed:
                        (_selected.isEmpty || _method == null || _paying)
                            ? null
                            : _confirm,
                    child: Text(_paying ? 'Salvataggio...' : '✓ Conferma'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(OrgScheduleConfig config, OrgSettingsService? settings, Booking b) {
    final now = DateTime.now();
    final past = lessonStart(b.date, b.time).isBefore(now);
    final d = DateTime.parse(b.date);
    return CheckboxListTile(
      value: _selected.contains(b.sbId),
      onChanged: (v) => setState(() {
        if (v == true) {
          _selected.add(b.sbId!);
        } else {
          _selected.remove(b.sbId);
        }
      }),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      tileColor: past ? const Color(0xFFFFF1F2) : null,
      title: Text('${d.day}/${d.month} ${b.time}',
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      subtitle: Text(config.slotName(b.slotType),
          style: const TextStyle(fontSize: 12)),
      secondary: Text('€${formatEuro(bookingPrice(b, settings, config))}',
          style: const TextStyle(
              fontWeight: FontWeight.w700, color: AppColors.dangerDark)),
    );
  }

  Future<void> _confirm() async {
    setState(() => _paying = true);
    final repo = await ref.read(adminRepositoryProvider.future);
    if (repo == null) {
      setState(() => _paying = false);
      return;
    }
    // lezione-gratuita → gratuito prima della RPC.
    final method = _method == 'lezione-gratuita' ? 'gratuito' : _method!;
    try {
      final n = await repo.payBookings(_selected.toList(), method);
      if (!mounted) return;
      Navigator.pop(context, true);
      AppSnack.success(
          context, '$n pagament${n == 1 ? 'o registrato' : 'i registrati'}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _paying = false);
      AppSnack.error(context, 'Errore: $e');
    }
  }
}

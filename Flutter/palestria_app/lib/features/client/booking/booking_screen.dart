import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../shared/area_switch.dart';
import 'calendar_view.dart';
import 'my_bookings_view.dart';

/// Tab Prenotazioni: Calendario (prenota) + Le mie (elenco).
/// Nel web sono due pagine (index.html / prenotazioni.html); qui una
/// pill-bar in alto con lo stesso stile .preno-tabs.
class BookingScreen extends ConsumerStatefulWidget {
  const BookingScreen({super.key});

  @override
  ConsumerState<BookingScreen> createState() => _BookingScreenState();
}

class _BookingScreenState extends ConsumerState<BookingScreen> {
  bool _showCalendar = true;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    Widget tab(String label, bool active, VoidCallback onTap) => Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: active ? primary : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
                boxShadow: active
                    ? [
                        BoxShadow(
                            color: primary.withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3)),
                      ]
                    : null,
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : AppColors.muted,
                ),
              ),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Prenotazioni'),
        actions: const [AdminAreaButton()],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: AppColors.slateBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  tab('Calendario', _showCalendar,
                      () => setState(() => _showCalendar = true)),
                  tab('Le mie', !_showCalendar,
                      () => setState(() => _showCalendar = false)),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _showCalendar ? const CalendarView() : const MyBookingsView(),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/area_switch.dart';
import 'calendar_view.dart';

/// Tab Prenotazioni: solo il calendario (prenota). L'elenco "Le mie" è stato
/// spostato nel Profilo (tab Prossime/Passate), come nella web app.
class BookingScreen extends ConsumerWidget {
  const BookingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prenotazioni'),
        actions: const [AdminAreaButton()],
      ),
      body: const CalendarView(),
    );
  }
}

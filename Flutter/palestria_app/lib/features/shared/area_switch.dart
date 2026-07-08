import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_providers.dart';

/// Bottone (per l'app bar admin) che apre l'area utente/cliente.
class UserAreaButton extends StatelessWidget {
  const UserAreaButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.person_outline),
      tooltip: 'Vista utente',
      onPressed: () => context.go('/client/prenotazioni'),
    );
  }
}

/// Bottone (per le app bar dell'area cliente) che torna all'area admin.
/// Visibile SOLO se l'utente è owner/admin della org.
class AdminAreaButton extends ConsumerWidget {
  const AdminAreaButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orgContext = ref.watch(orgContextProvider).value;
    if (orgContext == null || !orgContext.isOrgAdmin) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.admin_panel_settings_outlined),
      tooltip: 'Area admin',
      onPressed: () => context.go('/admin'),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_providers.dart';

/// Gate post-login: risolve il ruolo org (claim JWT `org_role` con ripiego su
/// `org_members`/`profiles`, come il web quando l'access-token-hook non è
/// registrato) e instrada verso area admin o cliente.
class SplashGate extends ConsumerWidget {
  const SplashGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/login');
      });
      return const _Loading();
    }

    final orgContext = ref.watch(orgContextProvider);
    return orgContext.when(
      loading: () => const _Loading(),
      error: (_, _) {
        // In dubbio, manda all'area cliente (l'admin resta autorevole lato server).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) context.go('/client/prenotazioni');
        });
        return const _Loading();
      },
      data: (ctx) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          context.go(ctx.isOrgAdmin ? '/admin' : '/client/prenotazioni');
        });
        return const _Loading();
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

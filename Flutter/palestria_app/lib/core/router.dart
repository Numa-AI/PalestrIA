import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_shell.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/recovery_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/auth/signup_trainer_screen.dart';
import '../features/auth/splash_gate.dart';
import '../features/client/client_shell.dart';
import '../features/client/booking/booking_screen.dart';
import '../features/client/profile/profile_screen.dart';
import '../features/client/workout/workout_screen.dart';
import '../features/staff/staff_screen.dart';
import 'auth/auth_providers.dart';

/// Notifica il router a ogni evento auth (login/logout → redirect).
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Stream<dynamic> stream) {
    _sub = stream.listen((_) => notifyListeners());
  }
  late final StreamSubscription<dynamic> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final client = ref.watch(supabaseProvider);
  final refresh = _AuthRefresh(client.auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = client.auth.currentSession;
      final onRecovery = state.matchedLocation == '/recovery';
      final onAuthPages =
          state.matchedLocation == '/login' ||
          state.matchedLocation.startsWith('/signup') ||
          state.matchedLocation.startsWith('/join') ||
          onRecovery;

      // Non autenticato: solo pagine auth.
      if (session == null) return onAuthPages ? null : '/login';

      // Autenticato ma sulle pagine auth: passa dal gate che risolve il ruolo
      // (claim org_role con ripiego su org_members/profiles).
      if (onRecovery) return null;
      if (onAuthPages) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SplashGate()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/recovery', builder: (_, _) => const RecoveryScreen()),
      GoRoute(path: '/signup', builder: (_, _) => const SignupScreen()),
      GoRoute(
        path: '/signup-trainer',
        builder: (_, _) => const SignupTrainerScreen(),
      ),
      // Deep link "iscriviti a questo studio": codice palestra dal link
      // (path /join/<codice> o query /join?code=<codice>) → registrazione
      // cliente precompilata. Ingresso: App Link https o schema palestria://.
      GoRoute(
        path: '/join/:code',
        builder: (_, state) =>
            SignupScreen(orgSlug: state.pathParameters['code']),
      ),
      GoRoute(
        path: '/join',
        builder: (_, state) =>
            SignupScreen(orgSlug: state.uri.queryParameters['code']),
      ),
      GoRoute(path: '/admin', builder: (_, _) => const _AdminGate()),
      GoRoute(path: '/staff', builder: (_, _) => const _StaffGate()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => ClientShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/client/prenotazioni',
                builder: (_, _) => const BookingScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/client/allenamento',
                builder: (_, _) => const WorkoutScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/client/profilo',
                builder: (_, _) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// Difesa client-side aggiuntiva: RLS/RPC restano l'autorità, ma un cliente
/// non deve poter montare l'interfaccia amministrativa tramite deep link.
class _AdminGate extends ConsumerWidget {
  const _AdminGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(orgContextProvider)
        .when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (_, _) => const _AdminDenied(),
          data: (org) =>
              org.isOrgAdmin ? const AdminShell() : const _AdminDenied(),
        );
  }
}

class _AdminDenied extends StatelessWidget {
  const _AdminDenied();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) context.go('/client/prenotazioni');
    });
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _StaffGate extends ConsumerWidget {
  const _StaffGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(orgContextProvider)
        .when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (_, _) => const _AdminDenied(),
          data: (org) => org.orgRole == 'staff'
              ? const StaffScreen()
              : const _AdminDenied(),
        );
  }
}

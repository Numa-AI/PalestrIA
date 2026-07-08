import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_shell.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/auth/splash_gate.dart';
import '../features/client/client_shell.dart';
import '../features/client/booking/booking_screen.dart';
import '../features/client/profile/profile_screen.dart';
import '../features/client/workout/workout_screen.dart';
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
      final onAuthPages = state.matchedLocation == '/login' ||
          state.matchedLocation.startsWith('/signup');

      // Non autenticato: solo pagine auth.
      if (session == null) return onAuthPages ? null : '/login';

      // Autenticato ma sulle pagine auth: passa dal gate che risolve il ruolo
      // (claim org_role con ripiego su org_members/profiles).
      if (onAuthPages) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SplashGate()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/signup', builder: (_, _) => const SignupScreen()),
      GoRoute(path: '/admin', builder: (_, _) => const AdminShell()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => ClientShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/prenotazioni',
              builder: (_, _) => const BookingScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/allenamento',
              builder: (_, _) => const WorkoutScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/profilo',
              builder: (_, _) => const ProfileScreen(),
            ),
          ]),
        ],
      ),
    ],
  );
});

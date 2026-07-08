import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'core/router.dart';
import 'core/theme/org_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Init di Supabase e snapshot branding sono indipendenti: avviali in
  // parallelo per accorciare il tempo al primo frame. Il preload branding
  // (equivalente di branding-boot.js: evita il flash col colore default prima
  // che arrivino le org settings) dipende solo dalle prefs, non da Supabase.
  final supabaseFuture = Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
  );
  final prefs = await SharedPreferences.getInstance();
  await OrgBrandingNotifier.preload(prefs);
  await supabaseFuture;

  runApp(const ProviderScope(child: PalestriaApp()));
}

class PalestriaApp extends ConsumerWidget {
  const PalestriaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branding = ref.watch(orgBrandingProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'PalestrIA',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(branding),
      routerConfig: router,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}

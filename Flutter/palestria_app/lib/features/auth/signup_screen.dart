import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_providers.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/ui_kit.dart';

/// Registrazione CLIENTE nel contesto di una palestra: nell'app (senza slug
/// nell'URL come sul web) il codice palestra viene chiesto esplicitamente.
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key, this.orgSlug});

  /// Se valorizzato (deep link "iscriviti a questo studio"), il codice palestra
  /// è pre-compilato e bloccato: il cliente non deve digitarlo.
  final String? orgSlug;

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _orgSlug = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _whatsapp = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;
  late final bool _lockedSlug;
  // null = in caricamento/errore (mostra il campo codice); '' = slug non valido
  // (avviso); valorizzato = nome studio risolto (banner, nasconde il codice).
  String? _studioName;

  @override
  void initState() {
    super.initState();
    final slug = widget.orgSlug?.trim().toLowerCase();
    _lockedSlug = slug != null && slug.isNotEmpty;
    if (_lockedSlug) {
      _orgSlug.text = slug!;
      _loadStudioName(slug);
    }
  }

  /// Risolve il NOME della palestra dallo slug (RPC pubblica) per mostrarlo in
  /// chiaro al cliente: dà fiducia e verifica che il link sia valido.
  Future<void> _loadStudioName(String slug) async {
    try {
      final res = await ref
          .read(supabaseProvider)
          .rpc('get_public_org_settings', params: {'p_org_slug': slug});
      final name = (res is Map) ? res['branding.studio_name'] as String? : null;
      if (mounted) {
        setState(
          () => _studioName = (name != null && name.trim().isNotEmpty)
              ? name.trim()
              : '',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _studioName = null);
    }
  }

  /// Header org: banner col nome studio (se risolto) o campo "Codice palestra".
  Widget _orgHeader() {
    if (_lockedSlug && (_studioName?.isNotEmpty ?? false)) {
      final primary = Theme.of(context).colorScheme.primary;
      return _studioBanner(
        icon: Icons.verified,
        color: primary,
        bg: primary.withValues(alpha: 0.08),
        title: 'Ti stai iscrivendo a',
        value: _studioName!,
      );
    }
    final children = <Widget>[];
    if (_lockedSlug && _studioName == '') {
      children.add(
        _studioBanner(
          icon: Icons.error_outline,
          color: AppColors.dangerDark,
          bg: AppColors.dangerSurface,
          title: '⚠️ Palestra non riconosciuta',
          value: 'Codice: ${widget.orgSlug}',
        ),
      );
      children.add(const SizedBox(height: AppSpacing.sm));
    }
    children.add(
      TextFormField(
        controller: _orgSlug,
        readOnly: _lockedSlug,
        decoration: InputDecoration(
          labelText: 'Codice palestra',
          prefixIcon: _lockedSlug ? const Icon(Icons.verified_outlined) : null,
          helperText: _lockedSlug
              ? 'Ti stai iscrivendo a questo studio.'
              : 'Te lo fornisce il tuo trainer (es. "studio-rossi").',
        ),
        validator: (v) => (v == null || v.trim().isEmpty)
            ? 'Inserisci il codice della tua palestra.'
            : null,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _studioBanner({
    required IconData icon,
    required Color color,
    required Color bg,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    for (final c in [_orgSlug, _name, _email, _whatsapp, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await ref
        .read(authRepositoryProvider)
        .registerClient(
          name: _name.text,
          email: _email.text,
          password: _password.text,
          orgSlug: _orgSlug.text,
          whatsapp: _whatsapp.text,
        );
    if (!mounted) return;
    setState(() => _loading = false);
    if (!result.ok) {
      setState(() => _error = result.error);
      return;
    }
    AppSnack.success(
      context,
      'Registrazione inviata! Se richiesto, conferma la tua email e poi accedi.',
    );
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('Registrati come cliente')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _orgHeader(),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'Nome e cognome',
                      ),
                      validator: (v) => (v == null || v.trim().length < 2)
                          ? 'Inserisci il tuo nome.'
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) => (v == null || !v.contains('@'))
                          ? 'Inserisci una email valida.'
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      controller: _whatsapp,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'WhatsApp (opzionale)',
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: (v) => (v == null || v.length < 6)
                          ? 'La password deve avere almeno 6 caratteri.'
                          : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        _error!,
                        style: const TextStyle(
                          color: AppColors.dangerDark,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Crea account'),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextButton(
                      onPressed: () => context.go('/login'),
                      child: const Text('Hai già un account? Accedi'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/theme/org_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/ui_kit.dart';

/// Login email/password (port di login.html — grafica da rifinire con
/// docs/spec-client.md).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
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
        .loginWithPassword(_email.text, _password.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (!result.ok) {
      setState(() => _error = result.error);
    }
    // Il redirect al login riuscito lo fa il router (refreshListenable).
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      AppSnack.error(context, 'Inserisci la tua email');
      return;
    }
    final result = await ref.read(authRepositoryProvider).resetPassword(email);
    if (!mounted) return;
    if (result.ok) {
      AppSnack.success(context, 'Email di recupero inviata: controlla la posta.');
    } else {
      AppSnack.error(context, result.error!);
    }
  }

  /// Logo dello studio (branding org), se disponibile: nessun placeholder se
  /// non c'è (fallback silenzioso, come richiesto — mai un'icona generica).
  Widget _orgLogo(OrgBranding branding) {
    final url = branding.logoUrl;
    if (url == null || url.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          width: 76,
          height: 76,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branding = ref.watch(orgBrandingProvider);
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.xxl),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.modalLg),
                  boxShadow: AppShadows.cardMd,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(child: _orgLogo(branding)),
                      Text('Accedi',
                          style: AppText.pageTitle, textAlign: TextAlign.center),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Entra nel tuo studio',
                        style: AppText.meta,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (v) => (v == null || !v.contains('@'))
                            ? 'Inserisci una email valida.'
                            : null,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          suffixIcon: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (v) => (v == null || v.length < 6)
                            ? 'La password deve avere almeno 6 caratteri.'
                            : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          _error!,
                          style: const TextStyle(
                              color: AppColors.dangerDark,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600),
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
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Accedi'),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextButton(
                        onPressed: _forgotPassword,
                        child: const Text('Password dimenticata?'),
                      ),
                      const Divider(height: AppSpacing.xxl),
                      Text('Non hai ancora un account?',
                          style: AppText.meta, textAlign: TextAlign.center),
                      const SizedBox(height: AppSpacing.md),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/signup'),
                        icon: const Icon(Icons.badge_outlined),
                        label: const Text(
                            'Sono un cliente — ho un codice palestra'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/signup-trainer'),
                        icon: const Icon(Icons.storefront_outlined),
                        label: const Text(
                            'Sono un personal trainer — crea studio'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

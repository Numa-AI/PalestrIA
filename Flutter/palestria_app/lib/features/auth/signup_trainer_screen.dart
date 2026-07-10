import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_providers.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/theme/tokens.dart';

/// Registrazione self-serve di un nuovo STUDIO (personal trainer): crea account
/// + organizzazione con trial 30gg. Port di signup-trainer.html ("Crea il tuo
/// studio"). Distinto da SignupScreen (registrazione CLIENTE via codice palestra).
class SignupTrainerScreen extends ConsumerStatefulWidget {
  const SignupTrainerScreen({super.key});

  @override
  ConsumerState<SignupTrainerScreen> createState() =>
      _SignupTrainerScreenState();
}

class _SignupTrainerScreenState extends ConsumerState<SignupTrainerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _studioName = TextEditingController();
  final _trainerName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  String? _info;
  String _slug = '';

  @override
  void initState() {
    super.initState();
    _studioName.addListener(_updateSlug);
  }

  void _updateSlug() {
    final s = ref.read(authRepositoryProvider).studioSlug(_studioName.text);
    if (s != _slug) setState(() => _slug = s);
  }

  @override
  void dispose() {
    _studioName.removeListener(_updateSlug);
    for (final c in [_studioName, _trainerName, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    final result = await ref
        .read(authRepositoryProvider)
        .registerTrainer(
          studioName: _studioName.text,
          trainerName: _trainerName.text,
          email: _email.text,
          password: _password.text,
        );
    if (!mounted) return;
    setState(() => _loading = false);
    if (result.ok) {
      // org creata + sessione rinfrescata: ririsolvi il contesto e vai al gate.
      ref.invalidate(orgContextProvider);
      if (mounted) context.go('/');
      return;
    }
    if (result.pendingEmail) {
      setState(() => _info = result.error);
      return;
    }
    setState(() => _error = result.error);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(title: const Text('Crea il tuo studio')),
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
                    Text(
                      'Registrati come personal trainer',
                      style: AppText.pageTitle,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '30 giorni di prova gratuita. Nessuna carta richiesta ora.',
                      style: AppText.meta,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    TextFormField(
                      controller: _studioName,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Nome dello studio / palestra',
                        hintText: 'Es. Studio Fitness Rossi',
                      ),
                      validator: (v) =>
                          ref
                                  .read(authRepositoryProvider)
                                  .studioSlug(v ?? '')
                                  .length <
                              3
                          ? 'Nome troppo corto (min. 3 lettere).'
                          : null,
                    ),
                    if (_slug.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Codice studio (i clienti lo useranno per iscriversi): $_slug',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      controller: _trainerName,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Il tuo nome',
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
                      controller: _password,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        helperText: 'Almeno 8 caratteri.',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) => (v == null || v.length < 8)
                          ? 'La password deve avere almeno 8 caratteri.'
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
                    if (_info != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        _info!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
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
                          : const Text('Crea studio e inizia la prova'),
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

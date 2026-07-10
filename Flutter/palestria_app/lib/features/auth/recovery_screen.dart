import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/theme/tokens.dart';
import '../../core/theme/ui_kit.dart';

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final result = await ref
        .read(authRepositoryProvider)
        .updatePassword(_password.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (!result.ok) {
      AppSnack.error(context, result.error ?? 'Aggiornamento non riuscito.');
      return;
    }
    AppSnack.success(context, 'Password aggiornata. Ora puoi accedere.');
    await ref.read(authRepositoryProvider).logout();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nuova password')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Imposta una nuova password', style: AppText.pageTitle),
                const SizedBox(height: AppSpacing.xl),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Nuova password',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                  validator: (value) => value == null || value.length < 8
                      ? 'Usa almeno 8 caratteri.'
                      : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Conferma password',
                  ),
                  validator: (value) => value != _password.text
                      ? 'Le password non coincidono.'
                      : null,
                ),
                const SizedBox(height: AppSpacing.xl),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: Text(_loading ? 'Salvataggio...' : 'Salva password'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

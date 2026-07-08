import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/tokens.dart';

/// Esercizio del catalogo (tabella `imported_exercises`).
class CatalogExercise {
  const CatalogExercise({
    required this.slug,
    required this.nomeIt,
    required this.categoria,
    this.thumbnail,
    this.popolarita = 0,
  });

  final String slug;
  final String nomeIt;
  final String categoria;
  final String? thumbnail;
  final int popolarita;
}

/// Catalogo caricato una volta per sessione (come il web).
final exerciseCatalogProvider =
    FutureProvider<List<CatalogExercise>>((ref) async {
  final rows = await ref
      .read(supabaseProvider)
      .from('imported_exercises')
      .select('slug, nome_it, categoria, immagine_thumbnail, popolarita')
      .order('popolarita', ascending: false)
      .timeout(const Duration(seconds: 30));
  return [
    for (final r in rows)
      CatalogExercise(
        slug: (r['slug'] as String?) ?? '',
        nomeIt: (r['nome_it'] as String?) ?? '',
        categoria: (r['categoria'] as String?) ?? 'Altro',
        thumbnail: r['immagine_thumbnail'] as String?,
        popolarita: (r['popolarita'] as num?)?.toInt() ?? 0,
      )
  ];
});

/// Risultato del picker: esercizio dal catalogo o personalizzato.
class PickedExercise {
  const PickedExercise({
    required this.name,
    this.slug,
    this.muscleGroup,
  });

  final String name;
  final String? slug;
  final String? muscleGroup;

  bool get isCardio => (muscleGroup ?? '').toLowerCase() == 'cardio';
}

/// Picker esercizi fullscreen (§8.5): ricerca, categorie, personalizzato.
Future<PickedExercise?> showExercisePicker(
    BuildContext context, String title) {
  return Navigator.of(context).push<PickedExercise>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _ExercisePickerPage(title: title),
  ));
}

class _ExercisePickerPage extends ConsumerStatefulWidget {
  const _ExercisePickerPage({required this.title});

  final String title;

  @override
  ConsumerState<_ExercisePickerPage> createState() =>
      _ExercisePickerPageState();
}

class _ExercisePickerPageState extends ConsumerState<_ExercisePickerPage> {
  String _query = '';
  String? _category;

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(exerciseCatalogProvider);

    return Scaffold(
      backgroundColor: AppColors.slateBg,
      appBar: AppBar(title: Text(widget.title)),
      body: catalogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Errore caricamento catalogo.')),
        data: (catalog) {
          final categories = <String, int>{};
          for (final e in catalog) {
            categories[e.categoria] = (categories[e.categoria] ?? 0) + 1;
          }

          final q = _query.trim().toLowerCase();
          var results = catalog.where((e) {
            if (_category != null && e.categoria != _category) return false;
            if (q.isNotEmpty && !e.nomeIt.toLowerCase().contains(q)) {
              return false;
            }
            return true;
          }).toList();
          final total = results.length;
          final overflow = total > 50 ? total - 50 : 0;
          results = results.take(50).toList();

          final showCategories = q.isEmpty && _category == null;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: TextField(
                  autofocus: false,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Cerca esercizio...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _category != null
                        ? InputChip(
                            label: Text(_category!),
                            onDeleted: () =>
                                setState(() => _category = null),
                          )
                        : null,
                  ),
                ),
              ),
              Expanded(
                child: showCategories
                    ? GridView.count(
                        crossAxisCount: 2,
                        childAspectRatio: 2.6,
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        children: [
                          for (final entry in categories.entries)
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _category = entry.key),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border:
                                      Border.all(color: AppColors.border),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(entry.key,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13.5)),
                                    ),
                                    Text('${entry.value}',
                                        style: const TextStyle(
                                            color: AppColors.subtle,
                                            fontSize: 12)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      )
                    : ListView(
                        children: [
                          for (final e in results)
                            ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: e.thumbnail == null
                                    ? Container(
                                        width: 44,
                                        height: 44,
                                        color: Colors.white,
                                        child: const Icon(
                                            Icons.fitness_center,
                                            size: 20,
                                            color: AppColors.subtle))
                                    : CachedNetworkImage(
                                        imageUrl: e.thumbnail!,
                                        width: 44,
                                        height: 44,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, _, _) =>
                                            Container(
                                                width: 44,
                                                height: 44,
                                                color: Colors.white)),
                              ),
                              title: Text(e.nomeIt,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14.5)),
                              subtitle: Text(e.categoria,
                                  style: const TextStyle(fontSize: 12.5)),
                              onTap: () => Navigator.pop(
                                  context,
                                  PickedExercise(
                                    name: e.nomeIt,
                                    slug: e.slug,
                                    muscleGroup: e.categoria,
                                  )),
                            ),
                          if (overflow > 0)
                            Padding(
                              padding: const EdgeInsets.all(AppSpacing.lg),
                              child: Text(
                                '$overflow altri — affina la ricerca',
                                textAlign: TextAlign.center,
                                style: AppText.meta,
                              ),
                            ),
                        ],
                      ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: OutlinedButton(
                    onPressed: _customExercise,
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44)),
                    child: const Text('✏️ Personalizzato'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _customExercise() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nome esercizio personalizzato:'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Aggiungi')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    Navigator.pop(context, PickedExercise(name: name));
  }
}

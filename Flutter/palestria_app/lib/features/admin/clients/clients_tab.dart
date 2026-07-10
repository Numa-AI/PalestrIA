import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'client_card.dart';

/// Filtri "mostra solo" (spec-admin §6.2), uno alla volta.
enum ClientFilter {
  none,
  cert('🏥 Senza certificato'),
  assic('📋 Senza assicurazione'),
  anag('📝 Senza anagrafica'),
  privacy('🔒 Anonimi'),
  push('🔕 Notifiche Disattivate');

  const ClientFilter([this.label = '']);
  final String label;
}

/// Modalità lista: nulla (nascosta), totali, attivi.
enum ClientsListMode { none, total, active }

class ClientsTab extends ConsumerStatefulWidget {
  const ClientsTab({super.key});

  @override
  ConsumerState<ClientsTab> createState() => _ClientsTabState();
}

class _ClientsTabState extends ConsumerState<ClientsTab> {
  final _searchController = TextEditingController();
  String _query = '';
  ClientFilter _filter = ClientFilter.none;
  ClientsListMode _mode = ClientsListMode.none;
  int _shown = 20;

  static const _pageSize = 20;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clientsAsync = ref.watch(adminClientsProvider);

    return clientsAsync.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore caricamento clienti:\n$e',
        onRetry: () {
          ref.invalidate(adminBookingsProvider);
          ref.invalidate(adminProfilesProvider);
        },
      ),
      data: (all) {
        final active = all.where((c) => c.isActive).toList();

        // Applica ricerca / filtro.
        List<AdminClient> visible;
        if (_query.trim().isNotEmpty) {
          final q = _query.trim().toLowerCase();
          visible = all
              .where(
                (c) =>
                    c.name.toLowerCase().contains(q) ||
                    (c.whatsapp ?? '').toLowerCase().contains(q) ||
                    (c.email ?? '').toLowerCase().contains(q),
              )
              .toList();
        } else if (_filter != ClientFilter.none) {
          final base = _mode == ClientsListMode.active ? active : all;
          visible = base.where(_matchesFilter).toList();
        } else if (_mode == ClientsListMode.active) {
          visible = active;
        } else if (_mode == ClientsListMode.total) {
          visible = all;
        } else {
          visible = const [];
        }

        final listVisible =
            _mode != ClientsListMode.none ||
            _filter != ClientFilter.none ||
            _query.trim().isNotEmpty;

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(adminBookingsProvider);
            ref.invalidate(adminProfilesProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              100,
            ),
            children: [
              _title(all.length, active.length),
              const SizedBox(height: AppSpacing.md),
              _searchBar(),
              const SizedBox(height: AppSpacing.md),
              _filterChips(),
              const SizedBox(height: AppSpacing.md),
              if (_filter != ClientFilter.none && _query.trim().isEmpty)
                _filterResult(visible.length)
              else if (_query.trim().isEmpty)
                _statCards(all.length, active.length),
              const SizedBox(height: AppSpacing.lg),
              if (listVisible) ...[
                if (visible.isEmpty)
                  const AppEmptyState(
                    title: 'Nessun cliente trovato',
                    compact: true,
                  )
                else ...[
                  for (final c in visible.take(_shown))
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: ClientCard(
                        key: ValueKey(c.userId ?? c.name),
                        client: c,
                      ),
                    ),
                  if (visible.length > _shown)
                    _loadMore(visible.length - _shown),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  bool _matchesFilter(AdminClient c) {
    final p = c.profile;
    final today = DateTime.now();
    switch (_filter) {
      case ClientFilter.cert:
        return p?.medicalCertExpiry == null ||
            p!.medicalCertExpiry!.isBefore(today);
      case ClientFilter.assic:
        return p?.insuranceExpiry == null ||
            p!.insuranceExpiry!.isBefore(today);
      case ClientFilter.anag:
        return p == null || p.anagraficaIncompleta;
      case ClientFilter.privacy:
        return p?.privacyPrenotazioni == true;
      case ClientFilter.push:
        return !(p?.pushEnabled ?? false);
      case ClientFilter.none:
        return true;
    }
  }

  Widget _title(int total, int active) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Clienti', style: AppText.pageTitle),
      Text('$total totali · $active attivi', style: AppText.meta),
    ],
  );

  Widget _searchBar() => TextField(
    controller: _searchController,
    onChanged: (v) => setState(() {
      _query = v;
      _shown = _pageSize;
    }),
    decoration: InputDecoration(
      hintText: 'Cerca cliente..',
      prefixIcon: const Icon(Icons.search, size: 20),
      suffixIcon: _query.isNotEmpty
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                _searchController.clear();
                setState(() => _query = '');
              },
            )
          : null,
    ),
  );

  Widget _filterChips() {
    Widget chip(ClientFilter f) {
      final active = _filter == f;
      return GestureDetector(
        onTap: () => setState(() {
          _filter = active ? ClientFilter.none : f;
          _shown = _pageSize;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? AppColors.dangerSurface : Colors.white,
            border: Border.all(
              color: active ? AppColors.danger : AppColors.borderGray,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            f.label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: active ? AppColors.dangerDark : AppColors.muted,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        chip(ClientFilter.cert),
        chip(ClientFilter.assic),
        chip(ClientFilter.anag),
        chip(ClientFilter.privacy),
        chip(ClientFilter.push),
      ],
    );
  }

  Widget _filterResult(int count) => Column(
    children: [
      Text(
        _filter.label,
        style: const TextStyle(fontSize: 15, color: Color(0xFF666666)),
      ),
      Text(
        '$count',
        style: const TextStyle(
          fontSize: 35,
          fontWeight: FontWeight.w700,
          color: AppColors.danger,
        ),
      ),
    ],
  );

  Widget _statCards(int total, int active) {
    Widget card(String emoji, String label, int value, ClientsListMode mode) {
      final isActive = _mode == mode;
      return Expanded(
        child: AppCard(
          onTap: () => setState(() {
            _mode = isActive ? ClientsListMode.none : mode;
            _shown = _pageSize;
          }),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          radius: AppRadius.cardLg,
          borderColor: isActive ? AppColors.primary : AppColors.border,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.slateBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
                  Text(
                    isActive ? 'Nascondi ▲' : 'Dettagli ▼',
                    style: TextStyle(
                      fontSize: 10,
                      color: isActive
                          ? AppColors.primary
                          : AppColors.borderHover,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: AppColors.subtle,
                ),
              ),
              Text(
                '$value',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.navy,
                  fontFeatures: AppText.tabularNums,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        card('👥', 'Clienti Totali', total, ClientsListMode.total),
        const SizedBox(width: AppSpacing.md),
        card('💪', 'Clienti Attivi', active, ClientsListMode.active),
      ],
    );
  }

  Widget _loadMore(int remaining) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.sm),
    child: OutlinedButton(
      onPressed: () => setState(() => _shown += _pageSize),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.muted,
        side: const BorderSide(color: AppColors.borderHover),
        minimumSize: const Size.fromHeight(44),
      ),
      child: Text(
        '▼ Mostra altri ${remaining < _pageSize ? remaining : _pageSize} clienti ($remaining rimanenti)',
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/theme/tokens.dart';
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Text('Errore caricamento clienti:\n$e',
              textAlign: TextAlign.center, style: AppText.meta),
        ),
      ),
      data: (all) {
        final active = all.where((c) => c.isActive).toList();

        // Applica ricerca / filtro.
        List<AdminClient> visible;
        if (_query.trim().isNotEmpty) {
          final q = _query.trim().toLowerCase();
          visible = all
              .where((c) =>
                  c.name.toLowerCase().contains(q) ||
                  (c.whatsapp ?? '').toLowerCase().contains(q) ||
                  (c.email ?? '').toLowerCase().contains(q))
              .toList();
        } else if (_filter != ClientFilter.none) {
          final base =
              _mode == ClientsListMode.active ? active : all;
          visible = base.where(_matchesFilter).toList();
        } else if (_mode == ClientsListMode.active) {
          visible = active;
        } else if (_mode == ClientsListMode.total) {
          visible = all;
        } else {
          visible = const [];
        }

        final listVisible = _mode != ClientsListMode.none ||
            _filter != ClientFilter.none ||
            _query.trim().isNotEmpty;

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(adminBookingsProvider);
            ref.invalidate(adminProfilesProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
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
                  const Padding(
                    padding: EdgeInsets.all(AppSpacing.xl),
                    child: Text('Nessun cliente trovato',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.subtle,
                            fontStyle: FontStyle.italic,
                            fontSize: 14)),
                  )
                else ...[
                  for (final c in visible.take(_shown))
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: ClientCard(key: ValueKey(c.userId ?? c.name), client: c),
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
          Text('$total totali · $active attivi',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.subtle, fontWeight: FontWeight.w500)),
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
            color: active ? const Color(0xFFFEF2F2) : Colors.white,
            border: Border.all(
                color: active
                    ? const Color(0xFFEF4444)
                    : const Color(0xFFE5E7EB),
                width: 1.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(f.label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? const Color(0xFFDC2626)
                      : const Color(0xFF6B7280))),
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
          Text(_filter.label,
              style: const TextStyle(fontSize: 15, color: Color(0xFF666666))),
          Text('$count',
              style: const TextStyle(
                  fontSize: 35,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFEF4444))),
        ],
      );

  Widget _statCards(int total, int active) {
    Widget card(String emoji, String label, int value, ClientsListMode mode) {
      final isActive = _mode == mode;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() {
            _mode = isActive ? ClientsListMode.none : mode;
            _shown = _pageSize;
          }),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: isActive
                      ? AppColors.primary
                      : const Color(0x0F000000),
                  width: isActive ? 1.5 : 1),
              boxShadow: AppShadows.card,
            ),
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
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(emoji, style: const TextStyle(fontSize: 20)),
                    ),
                    Text(isActive ? 'Nascondi ▲' : 'Dettagli ▼',
                        style: TextStyle(
                            fontSize: 10,
                            color: isActive
                                ? AppColors.primary
                                : const Color(0xFFD1D5DB))),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(label.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: Color(0xFF9CA3AF))),
                Text('$value',
                    style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111111),
                        fontFeatures: AppText.tabularNums)),
              ],
            ),
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
            foregroundColor: const Color(0xFF6B7280),
            side: const BorderSide(color: Color(0xFFD1D5DB)),
            minimumSize: const Size.fromHeight(44),
          ),
          child: Text(
              '▼ Mostra altri ${remaining < _pageSize ? remaining : _pageSize} clienti ($remaining rimanenti)'),
        ),
      );
}

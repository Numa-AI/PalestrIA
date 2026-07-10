import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';

/// Un solo canale condiviso per tutti i dati economici/prenotazioni dell'org.
/// I provider che lo osservano vengono ricalcolati a ogni tick Realtime.
final billingRealtimeTickProvider = StreamProvider.autoDispose<int>((
  ref,
) async* {
  final org = await ref.watch(orgContextProvider.future);
  if (org.orgId == null) {
    yield 0;
    return;
  }

  final client = ref.read(supabaseProvider);
  final controller = StreamController<int>();
  var tick = 0;
  var channel = client.channel('billing-live-${org.orgId}');
  for (final table in const [
    'client_balance_entries',
    'payments',
    'client_packages',
    'client_memberships',
    'bookings',
    'admin_audit_log',
  ]) {
    channel = channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: table,
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'org_id',
        value: org.orgId!,
      ),
      callback: (_) {
        if (!controller.isClosed) controller.add(++tick);
      },
    );
  }
  channel.subscribe();
  ref.onDispose(() {
    unawaited(controller.close());
    unawaited(client.removeChannel(channel));
  });

  yield 0;
  yield* controller.stream;
});

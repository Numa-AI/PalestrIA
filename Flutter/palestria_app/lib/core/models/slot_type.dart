import 'dart:ui';

import '../theme/org_theme.dart';

/// Tipo di lezione per-org (tabella `slot_types`).
class SlotType {
  const SlotType({
    required this.id,
    required this.key,
    required this.label,
    required this.color,
    required this.defaultCapacity,
    required this.defaultPrice,
    required this.bookable,
    required this.isActive,
    required this.sortOrder,
  });

  final String id;
  final String key;
  final String label;
  final Color color;
  final int defaultCapacity;
  final double defaultPrice;
  final bool bookable;
  final bool isActive;
  final int sortOrder;

  static SlotType fromRow(Map<String, dynamic> row) => SlotType(
    id: row['id'] as String,
    key: row['key'] as String,
    label: (row['label'] as String?) ?? (row['key'] as String),
    color:
        OrgBranding.parseHex(row['color'] as String?) ??
        const Color(0xFF8B5CF6),
    defaultCapacity: (row['default_capacity'] as num?)?.toInt() ?? 1,
    defaultPrice: (row['default_price'] as num?)?.toDouble() ?? 0,
    bookable: (row['bookable'] as bool?) ?? true,
    isActive: (row['is_active'] as bool?) ?? true,
    sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'key': key,
    'label': label,
    'color':
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
    'default_capacity': defaultCapacity,
    'default_price': defaultPrice,
    'bookable': bookable,
    'is_active': isActive,
    'sort_order': sortOrder,
  };
}

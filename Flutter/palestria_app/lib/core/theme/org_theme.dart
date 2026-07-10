import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tokens.dart';

/// Branding per-org (equivalente di branding-boot.js + org_settings `branding.*`).
/// Il colore primario arriva da `branding.primary_color`; il "dark" è derivato
/// a runtime scurendo del 10% (RGB × 0.9), come fa il JS.
class OrgBranding {
  const OrgBranding({
    this.primary = AppColors.primary,
    this.logoUrl,
    this.studioName,
  });

  final Color primary;
  final String? logoUrl;
  final String? studioName;

  Color get primaryDark => Color.fromARGB(
        255,
        ((primary.r * 255.0) * 0.9).round().clamp(0, 255),
        ((primary.g * 255.0) * 0.9).round().clamp(0, 255),
        ((primary.b * 255.0) * 0.9).round().clamp(0, 255),
      );

  /// Gradiente primario 135deg usato da bottoni/tab attive/dock.
  LinearGradient get primaryGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [primary, primaryDark],
      );

  Map<String, dynamic> toJson() => {
        'primary': primary.toARGB32(),
        'logoUrl': logoUrl,
        'studioName': studioName,
      };

  static OrgBranding fromJson(Map<String, dynamic> json) => OrgBranding(
        primary: Color(json['primary'] as int? ?? 0xFF8B5CF6),
        logoUrl: json['logoUrl'] as String?,
        studioName: json['studioName'] as String?,
      );

  static Color? parseHex(String? hex) {
    if (hex == null) return null;
    final h = hex.replaceFirst('#', '').trim();
    if (h.length == 6) return Color(int.parse('FF$h', radix: 16));
    if (h.length == 8) return Color(int.parse(h, radix: 16));
    return null;
  }
}

/// Snapshot pre-paint del branding (equivalente di `_brandingSnapshot` in
/// localStorage): evita il flash viola-default all'avvio.
class OrgBrandingNotifier extends Notifier<OrgBranding> {
  static const _snapshotKey = 'branding_snapshot';

  @override
  OrgBranding build() => _initial;

  static OrgBranding _initial = const OrgBranding();

  /// Da chiamare PRIMA di runApp per caricare lo snapshot persistito.
  static Future<void> preload(SharedPreferences prefs) async {
    final raw = prefs.getString(_snapshotKey);
    if (raw == null) return;
    try {
      _initial =
          OrgBranding.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // snapshot corrotto: si riparte dal default
    }
  }

  Future<void> apply(OrgBranding branding) async {
    state = branding;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_snapshotKey, jsonEncode(branding.toJson()));
  }

  Future<void> reset() async {
    state = const OrgBranding();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_snapshotKey);
  }
}

final orgBrandingProvider =
    NotifierProvider<OrgBrandingNotifier, OrgBranding>(OrgBrandingNotifier.new);

/// ThemeData dell'app costruito dai design tokens + branding org corrente.
ThemeData buildAppTheme(OrgBranding branding) {
  final primary = branding.primary;

  final colorScheme = ColorScheme.light(
    primary: primary,
    onPrimary: Colors.white,
    secondary: branding.primaryDark,
    onSecondary: Colors.white,
    error: AppColors.danger,
    onError: Colors.white,
    surface: AppColors.surface,
    onSurface: AppColors.navy,
    outline: AppColors.border,
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: kFontFamily,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.lightGray,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.navy,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: kFontFamily,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
        color: AppColors.navy,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: const BorderSide(color: AppColors.border),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(
            fontFamily: kFontFamily, fontSize: 15, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.slate800,
        side: const BorderSide(color: AppColors.border),
        textStyle: const TextStyle(
            fontFamily: kFontFamily, fontSize: 15, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: primary,
        textStyle: const TextStyle(
            fontFamily: kFontFamily, fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: primary, width: 2),
      ),
      hintStyle: const TextStyle(
          fontFamily: kFontFamily, color: AppColors.subtle, fontSize: 15),
      labelStyle: AppText.label,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.navy,
      contentTextStyle:
          const TextStyle(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.toast),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.modal),
      ),
    ),
  );
}

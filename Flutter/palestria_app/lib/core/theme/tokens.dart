import 'package:flutter/material.dart';

/// Famiglia tipografica unica dell'app (bundled in assets/fonts, vedi pubspec).
/// Inter: alta leggibilità UI + ottime cifre tabulari. Cambiare font = cambiare
/// questa costante + il pubspec: la tipografia si aggiorna in un punto solo.
const String kFontFamily = 'Inter';

/// Design tokens estratti 1:1 dal CSS della web app (docs/design-tokens.md).
/// La web app è light-only: nessun dark mode.
class AppColors {
  AppColors._();

  // Brand (override per-org a runtime via OrgBranding)
  static const primary = Color(0xFF8B5CF6); // --primary-purple
  static const primaryDark = Color(0xFF7C3AED); // --primary-purple-dark

  // Superfici
  static const darkBg = Color(0xFF1A1A1A); // navbar/footer/hero
  static const darkGray = Color(0xFF2D2D2D);
  static const lightGray = Color(0xFFF8F9FA); // sfondo pagina base
  static const slateBg = Color(0xFFF1F5F9); // sfondo pagine slate (allenamento/admin)
  static const surface = Color(0xFFFFFFFF);

  // Testo
  static const textDark = Color(0xFF333333); // body default
  static const navy = Color(0xFF0F172A); // heading (slate-900)
  static const slate800 = Color(0xFF1E293B);
  static const muted = Color(0xFF64748B); // testo secondario (slate-500)
  static const subtle = Color(0xFF94A3B8); // terziario/placeholder (slate-400)

  // Bordi
  static const border = Color(0xFFE2E8F0); // slate-200
  static const borderHover = Color(0xFFCBD5E1); // slate-300
  static const borderGray = Color(0xFFE5E7EB); // gray-200

  // Semantici
  static const success = Color(0xFF06D6A0); // verde-teal (toast, badge confirmed)
  static const successEmerald = Color(0xFF10B981);
  static const successEmeraldDark = Color(0xFF059669);
  static const warning = Color(0xFFF77F00);
  static const amber = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
  static const dangerDark = Color(0xFFDC2626);
  static const cyan = Color(0xFF06B6D4);

  // Tinte glow / focus
  static const purpleGlow = Color(0x1F8B5CF6); // rgba(139,92,246,0.12)
  static const purpleGlowStrong = Color(0x388B5CF6); // 0.22

  // Colori tipo-slot DEFAULT (org demo) — a runtime arrivano da slot_types.color
  static const slotPersonalTraining = Color(0xFF22C55E);
  static const slotSmallGroup = Color(0xFFFBBF24);
  static const slotGroupClass = Color(0xFFEF4444);
  static const slotCleaning = Color(0xFF8B5CF6);

  // Chip stati pagamento (sfondo / testo)
  static const paidBg = Color(0xFFDCFCE7);
  static const paidText = Color(0xFF166534);
  static const unpaidBg = Color(0xFFFEF9C3);
  static const unpaidText = Color(0xFF854D0E);
  static const partialBg = Color(0xFFEDE9FE);
  static const partialText = Color(0xFF5B21B6);
  static const cancelledBg = Color(0xFFF3F4F6);
  static const cancelledText = Color(0xFF6B7280);
  static const cancelReqBg = Color(0xFFFEF3C7);
  static const cancelReqText = Color(0xFF92400E);

  // WhatsApp
  static const whatsapp = Color(0xFF25D366);

  // Superfici "soft" per box/badge tenui
  static const dangerSurface = Color(0xFFFEF2F2);
  static const warnSurface = Color(0xFFFFFBEB);
  static const successSurface = Color(0xFFF0FDF4);
  static const infoSurface = Color(0xFFEFF6FF);
  static const slate50 = Color(0xFFF8FAFC);

  // Verdi "attivo/incassato" (distinti dal teal `success` #06D6A0)
  static const green500 = Color(0xFF22C55E);
  static const green600 = Color(0xFF16A34A);
  static const green700 = Color(0xFF15803D);

  // Blu (registro/booking, grafici)
  static const blue500 = Color(0xFF3B82F6);
  static const blue600 = Color(0xFF2563EB);

  // Indicatore posti residui: 1→danger, 2→spotsOrange, ≥3→navy
  static const spotsOrange = Color(0xFFEA7B0A);

  // Stati documento (certificato/assicurazione/anagrafica) — coppie bg/testo
  static const docOkBg = Color(0xFFF0FDF4);
  static const docOkText = Color(0xFF166534);
  static const docWarnBg = Color(0xFFFFFBEB);
  static const docWarnText = Color(0xFF92400E);
  static const docDangerBg = Color(0xFFFEF2F2);
  static const docDangerText = Color(0xFFDC2626);

  // Avatar partecipanti: 6 tinte stabili (hash sul nome) — [sfondo, testo]
  static const avatarTints = <(Color, Color)>[
    (Color(0xFFCDECF9), Color(0xFF0B7FB0)),
    (Color(0xFFFEF3C7), Color(0xFFB45309)),
    (Color(0xFFF3E8FF), Color(0xFF7E22CE)),
    (Color(0xFFDCFCE7), Color(0xFF166534)),
    (Color(0xFFFEE2E2), Color(0xFFB91C1C)),
    (Color(0xFFE0F2FE), Color(0xFF075985)),
  ];
}

/// Scala spaziature (px, 4-based come da suggerimento della spec).
class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const xxxl = 32.0;
}

/// Border-radius per componente (dal CSS).
class AppRadius {
  AppRadius._();
  static const button = 8.0; // mobile
  static const buttonAdmin = 10.0;
  static const input = 10.0;
  static const card = 14.0;
  static const cardLg = 16.0; // stat card, --all-radius
  static const modal = 16.0;
  static const modalLg = 18.0;
  static const sheet = 20.0; // solo in alto
  static const chip = 999.0; // pill
  static const toast = 12.0;
}

/// Ombre (box-shadow esatte dal CSS).
class AppShadows {
  AppShadows._();

  /// --all-shadow (card a riposo)
  static const card = [
    BoxShadow(color: Color(0x0F0F172A), blurRadius: 3, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A0F172A), blurRadius: 2, offset: Offset(0, 1)),
  ];

  /// --all-shadow-md (hover/elevata)
  static const cardMd = [
    BoxShadow(color: Color(0x140F172A), blurRadius: 16, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x0A0F172A), blurRadius: 4, offset: Offset(0, 2)),
  ];

  /// --all-shadow-lg (overlay/modali)
  static const cardLg = [
    BoxShadow(color: Color(0x1F0F172A), blurRadius: 32, offset: Offset(0, 12)),
    BoxShadow(color: Color(0x0F0F172A), blurRadius: 8, offset: Offset(0, 4)),
  ];

  /// focus/selected (glow viola) — col colore brand di default
  static const glow = [
    BoxShadow(color: Color(0x1F8B5CF6), blurRadius: 0, spreadRadius: 3),
    BoxShadow(color: Color(0x1A8B5CF6), blurRadius: 16, offset: Offset(0, 4)),
  ];
}

/// Stili di testo ricorrenti. Font unico: [kFontFamily] (Inter, bundled).
/// Numeri sempre tabular (font-variant-numeric: tabular-nums del CSS).
/// La `fontFamily` è impostata esplicitamente su ogni stile così che restino
/// corretti anche se usati fuori dal contesto del tema (TextSpan, PDF-preview…).
class AppText {
  AppText._();

  static const tabularNums = [FontFeature.tabularFigures()];

  static const pageTitle = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 26.4,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.5,
    color: AppColors.navy,
    height: 1.2,
  );

  static const sectionTitle = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 22.4,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.4,
    color: AppColors.navy,
  );

  static const cardTitle = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.16,
    color: AppColors.navy,
  );

  static const body = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: AppColors.textDark,
    height: 1.55,
  );

  static const label = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    color: Color(0xFF444444),
  );

  static const meta = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.muted,
  );

  static const badge = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
  );

  /// Eyebrow / group label: UPPERCASE con letter-spacing largo
  static const eyebrow = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.1,
    color: AppColors.muted,
  );

  /// Valori KPI (stat card)
  static const statValue = TextStyle(
    fontFamily: kFontFamily,
    fontSize: 32,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.64,
    height: 1.15,
    color: AppColors.navy,
    fontFeatures: tabularNums,
  );
}

/// Gradienti FISSI (non legati al branding org).
class AppGradients {
  AppGradients._();

  /// Hero "Athletic" delle sezioni scure (Scheda/Progressi/Report/Profilo).
  /// Volutamente fisso come nel web: non deriva dal colore brand della org.
  static const workoutHero = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0F172A), Color(0xFF1E1B4B), Color(0xFF7C3AED)],
    stops: [0, 0.55, 1],
  );
}

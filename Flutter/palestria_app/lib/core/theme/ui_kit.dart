import 'package:flutter/material.dart';

import 'tokens.dart';

/// UI KIT condiviso di PalestrIA.
///
/// Questi widget sono la "linea unica" del design (vedi `docs/DESIGN_SYSTEM.md`):
/// invece di ricostruire card/empty-state/pill/bottoni gradiente a mano in ogni
/// schermata (con padding, radius e ombre che divergono), le schermate usano
/// questi componenti. Tutti leggono i design token da [tokens.dart] e il colore
/// brand dal `Theme` corrente (org-aware: `colorScheme.primary`/`secondary`
/// sono impostati da `buildAppTheme` col branding della org).

/// Gradiente brand 135° (primary → primaryDark). `secondary` nel tema è il
/// primaryDark derivato dall'org, quindi è org-aware senza dipendere da Riverpod.
LinearGradient brandGradient(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [cs.primary, cs.secondary],
  );
}

/// Card standard: bianca, radius 14, bordo slate-200, ombra doppia leggera.
/// Opzionale una barra colore a sinistra (codifica tipo/severità, 4–5px).
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.onTap,
    this.leftBarColor,
    this.leftBarWidth = 4,
    this.background = AppColors.surface,
    this.radius = AppRadius.card,
    this.borderColor = AppColors.border,
    this.elevated = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final Color? leftBarColor;
  final double leftBarWidth;
  final Color background;
  final double radius;
  final Color borderColor;

  /// true → ombra `md` (card in evidenza), altrimenti ombra `card` a riposo.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    Widget content = child;
    if (leftBarColor != null) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: leftBarWidth, color: leftBarColor),
          Expanded(
            child: Padding(padding: padding, child: child),
          ),
        ],
      );
    } else {
      content = Padding(padding: padding, child: child);
    }

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor),
        boxShadow: elevated ? AppShadows.cardMd : AppShadows.card,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );

    if (onTap == null) {
      return Container(margin: margin, child: decorated);
    }
    return Container(
      margin: margin,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: decorated,
        ),
      ),
    );
  }
}

/// Intestazione di sezione: eyebrow UPPERCASE opzionale + titolo, con spaziatura
/// coerente. Usare al posto di `Text` sciolti per i titoli di sezione/pagina.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.trailing,
    this.padding = EdgeInsets.zero,
  });

  final String title;
  final String? eyebrow;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null) ...[
                  Text(eyebrow!.toUpperCase(),
                      style: AppText.eyebrow.copyWith(color: primary)),
                  const SizedBox(height: 4),
                ],
                Text(title, style: AppText.sectionTitle),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Empty state coerente: icona tenue + titolo + sottotitolo, centrato.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.action,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: compact ? AppSpacing.xl : AppSpacing.xxxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 34 : 44, color: AppColors.subtle),
              const SizedBox(height: AppSpacing.md),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppText.cardTitle.copyWith(color: AppColors.muted),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: AppText.meta.copyWith(color: AppColors.subtle, height: 1.5),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Pill di stato/etichetta (coppie bg/fg dai token — vedi §1.6 design-tokens).
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: AppText.badge.copyWith(
                  color: foreground, fontSize: dense ? 11 : 12)),
        ],
      ),
    );
  }
}

/// Bottone primario a gradiente brand con press-scale e ombra tinta.
/// Equivalente del `.btn-primary` gradient admin del web.
class GradientButton extends StatefulWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.height = 48,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final double height;

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final primary = Theme.of(context).colorScheme.primary;
    final btn = AnimatedScale(
      scale: _down && enabled ? 0.97 : 1,
      duration: const Duration(milliseconds: 110),
      child: Container(
        height: widget.height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        decoration: BoxDecoration(
          gradient: enabled ? brandGradient(context) : null,
          color: enabled ? null : AppColors.borderHover,
          borderRadius: BorderRadius.circular(AppRadius.buttonAdmin),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.30),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: widget.loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.4, color: Colors.white),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Text(widget.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      )),
                ],
              ),
      ),
    );

    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTap: enabled ? widget.onPressed : null,
      child: widget.expand ? SizedBox(width: double.infinity, child: btn) : btn,
    );
  }
}

/// Hero scuro→viola riusabile (prenotazioni, assegna scheda, profilo, report).
/// Gradiente `#0f172a → #1e1b4b → primaryDark` + glow radiale interno.
class DarkHero extends StatelessWidget {
  const DarkHero({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.xl),
    this.radius = AppRadius.modalLg,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        // Diagonale near-black → viola-scuro → primaryDark org (replica .preno-hero).
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF1A1A1A), const Color(0xFF2A1F3D), cs.secondary],
          stops: const [0, 0.5, 1],
        ),
        boxShadow: [
          BoxShadow(
            color: cs.secondary.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            // Alone radiale viola in basso a destra (rgba(brand, 0.45)).
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.75, 0.85),
                    radius: 0.95,
                    colors: [cs.primary.withValues(alpha: 0.45), Colors.transparent],
                    stops: const [0, 0.62],
                  ),
                ),
              ),
            ),
            // Ring interno sottile (inset ring rgba(255,255,255,0.06)).
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
              ),
            ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

/// Stat card KPI: barra gradiente in alto, tile icona tinta, label UPPERCASE,
/// valore grande a peso 800. Coerente con §4.2 design-tokens.
class AppStatCard extends StatelessWidget {
  const AppStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.buttonAdmin),
          ),
          child: Icon(icon, size: 20, color: accent),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(label.toUpperCase(), style: AppText.eyebrow),
        const SizedBox(height: 4),
        Text(value, style: AppText.statValue),
      ],
    );
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accent, accent.withValues(alpha: 0.6)],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: content,
          ),
        ],
      ),
    );
  }
}

/// Spinner brandizzato centrato.
class AppLoading extends StatelessWidget {
  const AppLoading({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
                strokeWidth: 3, backgroundColor: AppColors.border),
          ),
          if (label != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(label!, style: AppText.meta),
          ],
        ],
      ),
    );
  }
}

/// Stato di errore con retry, coerente in tutte le schermate async.
class AppErrorRetry extends StatelessWidget {
  const AppErrorRetry({
    super.key,
    this.message = 'Qualcosa è andato storto',
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 40, color: AppColors.subtle),
            const SizedBox(height: AppSpacing.md),
            Text(message,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.muted)),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Riprova'),
            ),
          ],
        ),
      ),
    );
  }
}

/// SnackBar colorati per esito: verde (successo) / rosso (errore) / viola (info).
/// Sostituisce lo SnackBar navy uniforme, così un errore non "sembra" un successo.
class AppSnack {
  AppSnack._();

  static void success(BuildContext context, String message) =>
      _show(context, message, AppColors.successEmerald, Icons.check_circle_rounded);

  static void error(BuildContext context, String message) =>
      _show(context, message, AppColors.danger, Icons.error_rounded);

  static void info(BuildContext context, String message) =>
      _show(context, message, Theme.of(context).colorScheme.primary,
          Icons.info_rounded);

  static void _show(
      BuildContext context, String message, Color bg, IconData icon) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
                child: Text(message,
                    style: const TextStyle(color: Colors.white))),
          ],
        ),
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
      ));
  }
}

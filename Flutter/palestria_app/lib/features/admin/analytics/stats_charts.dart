import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';

/// Grafico a linea dell'andamento prenotazioni nel tempo (equivalente di
/// `drawBookingsChart` / `SimpleChart.drawLineChart`). Area sfumata + linea +
/// etichette asse X diradate. Nessuna libreria esterna.
class BookingsLineChart extends StatelessWidget {
  const BookingsLineChart({
    super.key,
    required this.labels,
    required this.values,
    this.color = const Color(0xFFE63946),
    this.height = 190,
  });

  final List<String> labels;
  final List<num> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final hasData = values.any((v) => v > 0);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: hasData
          ? CustomPaint(painter: _LinePainter(labels, values, color))
          : const Center(
              child: Text('Nessun dato nel periodo',
                  style: AppText.meta)),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.labels, this.values, this.color);

  final List<String> labels;
  final List<num> values;
  final Color color;

  static const _padLeft = 30.0;
  static const _padBottom = 22.0;
  static const _padTop = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final chartW = size.width - _padLeft;
    final chartH = size.height - _padBottom - _padTop;
    final maxV = math.max(1, values.reduce((a, b) => a > b ? a : b).toDouble());

    // Gridlines orizzontali + etichette Y (0, metà, max).
    final gridPaint = Paint()
      ..color = const Color(0xFFEEF2F7)
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = _padTop + chartH * (i / 2);
      canvas.drawLine(Offset(_padLeft, y), Offset(size.width, y), gridPaint);
      final val = (maxV * (1 - i / 2)).round();
      _text(canvas, '$val', Offset(0, y - 6),
          const TextStyle(fontSize: 9, color: Color(0xFF9CA3AF)), maxWidth: _padLeft - 4, align: TextAlign.right);
    }

    Offset pt(int i) {
      final x = values.length == 1
          ? _padLeft + chartW / 2
          : _padLeft + i * chartW / (values.length - 1);
      final y = _padTop + chartH - (values[i] / maxV) * chartH;
      return Offset(x, y);
    }

    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(pt(values.length - 1).dx, _padTop + chartH)
      ..lineTo(pt(0).dx, _padTop + chartH)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.02)],
        ).createShader(Rect.fromLTWH(_padLeft, _padTop, chartW, chartH)),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Etichette asse X diradate (max ~8).
    final step = (labels.length / 8).ceil().clamp(1, labels.length);
    for (var i = 0; i < labels.length; i++) {
      if (i % step != 0 || labels[i].isEmpty) continue;
      final x = pt(i).dx;
      _text(canvas, labels[i], Offset(x - 14, size.height - _padBottom + 5),
          const TextStyle(fontSize: 9, color: Color(0xFF9CA3AF)),
          maxWidth: 28, align: TextAlign.center);
    }
  }

  void _text(Canvas canvas, String s, Offset at, TextStyle style,
      {double maxWidth = 60, TextAlign align = TextAlign.left}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    )..layout(maxWidth: maxWidth);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.values != values || old.color != color;
}

/// Grafico a barre mensile (equivalente di `SimpleChart.drawBarChart`):
/// per ogni mese una barra impilata solido + proiezione + stima, col mese
/// corrente evidenziato. Usato dal drill-down Fatturato (12 mesi + successivo).
class MonthlyBarChart extends StatelessWidget {
  const MonthlyBarChart({
    super.key,
    required this.labels,
    required this.solid,
    this.projected,
    this.estimate,
    this.highlightIndex,
    this.barColor,
    this.projectedColor,
    this.height = 170,
  });

  final List<String> labels;
  final List<num> solid;
  final List<num>? projected;
  final List<num>? estimate;
  final int? highlightIndex;

  /// Colore delle barre "solide" (default viola). Il mese evidenziato usa un
  /// tono più scuro dello stesso colore.
  final Color? barColor;

  /// Colore della porzione "proiezione/futuro" (default ambra).
  final Color? projectedColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = <double>[
      for (var i = 0; i < solid.length; i++)
        solid[i].toDouble() +
            (projected != null ? projected![i].toDouble() : 0) +
            (estimate != null ? estimate![i].toDouble() : 0)
    ];
    if (total.every((v) => v <= 0)) {
      return SizedBox(
        height: height,
        child: const Center(
            child: Text('Nessun dato nel periodo', style: AppText.meta)),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BarPainter(labels, solid, projected, estimate,
            highlightIndex, barColor, projectedColor),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.labels, this.solid, this.projected, this.estimate,
      this.highlight, this.barColor, this.projectedColor);

  final List<String> labels;
  final List<num> solid;
  final List<num>? projected;
  final List<num>? estimate;
  final int? highlight;
  final Color? barColor;
  final Color? projectedColor;

  static const _padBottom = 20.0;
  static const _padTop = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final n = solid.length;
    if (n == 0) return;
    final chartH = size.height - _padBottom - _padTop;
    final slotW = size.width / n;
    final barW = slotW * 0.6;

    double stacked(int i) =>
        solid[i].toDouble() +
        (projected != null ? projected![i].toDouble() : 0) +
        (estimate != null ? estimate![i].toDouble() : 0);
    final maxV = math.max(
        1.0, List.generate(n, stacked).reduce((a, b) => a > b ? a : b));

    for (var i = 0; i < n; i++) {
      final cx = slotW * i + slotW / 2;
      final left = cx - barW / 2;
      var yBase = _padTop + chartH;

      void segment(double value, Color color) {
        if (value <= 0) return;
        final h = (value / maxV) * chartH;
        final top = yBase - h;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(left, top, barW, h),
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
          Paint()..color = color,
        );
        yBase = top;
      }

      final isCurrent = highlight != null && i == highlight;
      final base = barColor ?? const Color(0xFFC4B5FD);
      final current = barColor != null
          ? (Color.lerp(barColor, Colors.black, 0.22) ?? barColor!)
          : AppColors.primaryDark;
      segment(solid[i].toDouble(), isCurrent ? current : base);
      if (projected != null) {
        segment(projected![i].toDouble(), projectedColor ?? AppColors.amber);
      }
      if (estimate != null) {
        segment(estimate![i].toDouble(), const Color(0x5522C55E));
      }

      // Etichetta mese (una ogni 2 se troppe).
      final step = n > 8 ? 2 : 1;
      if (i % step == 0 && i < labels.length) {
        final tp = TextPainter(
          text: TextSpan(
              text: labels[i],
              style: const TextStyle(fontSize: 8.5, color: Color(0xFF9CA3AF))),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(cx - tp.width / 2, size.height - _padBottom + 4));
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.solid != solid || old.projected != projected;
}

/// Fetta della torta/ciambella.
class DonutSlice {
  const DonutSlice(this.label, this.value, this.color);
  final String label;
  final num value;
  final Color color;
}

/// Grafico a ciambella per la ripartizione per tipo (equivalente di
/// `drawTypeChart` / `SimpleChart.drawPieChart`) con legenda.
class TypeDonutChart extends StatelessWidget {
  const TypeDonutChart({super.key, required this.slices, this.size = 150});

  final List<DonutSlice> slices;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visible = slices.where((s) => s.value > 0).toList();
    if (visible.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(
            child: Text('Nessun dato nel periodo', style: AppText.meta)),
      );
    }
    final total = visible.fold<double>(0, (s, e) => s + e.value);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _DonutPainter(visible)),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in visible)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: s.color,
                            borderRadius: BorderRadius.circular(3)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(s.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                      Text(
                        '${s.value.round()} · ${(s.value / total * 100).round()}%',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.slices);
  final List<DonutSlice> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (s, e) => s + e.value);
    if (total <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final stroke = radius * 0.38;
    final rect = Rect.fromCircle(center: center, radius: radius - stroke / 2);
    var start = -math.pi / 2;
    for (final s in slices) {
      final sweep = (s.value / total) * 2 * math.pi;
      canvas.drawArc(
        rect,
        start,
        sweep - 0.02,
        false,
        Paint()
          ..color = s.color
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt
          ..style = PaintingStyle.stroke,
      );
      start += sweep;
    }
    // Totale al centro.
    final tp = TextPainter(
      text: TextSpan(children: [
        TextSpan(
            text: '${total.round()}\n',
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111111))),
        const TextSpan(
            text: 'tot',
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
      ]),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas,
        Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.slices != slices;
}

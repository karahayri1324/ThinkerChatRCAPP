import 'package:flutter/material.dart';

/// A small time-series line chart with a soft gradient fill, used by the
/// dashboard cards to show recent history (CPU %, memory %, net speed).
class Sparkline extends StatelessWidget {
  final List<double> values;

  /// Fixed y-axis maximum (e.g. 100 for percentages). When null the chart
  /// auto-scales to the data's max.
  final double? maxY;
  final Color color;
  final double height;

  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.maxY,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(List.of(values), maxY, color),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final double? maxY;
  final Color color;

  _SparklinePainter(this.values, this.maxY, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0 || size.height <= 0) return;
    var top = maxY ?? values.reduce((a, b) => a > b ? a : b);
    if (top <= 0) top = 1;

    final dx = size.width / (values.length - 1);
    Offset point(int i) {
      final norm = (values[i] / top).clamp(0.0, 1.0);
      // Inset 1px vertically so the stroke isn't clipped at the extremes.
      return Offset(i * dx, 1 + (1 - norm) * (size.height - 2));
    }

    final line = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(point(i).dx, point(i).dy);
    }

    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.30), color.withOpacity(0.02)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color || old.maxY != maxY || !listEquals(old.values, values);
}

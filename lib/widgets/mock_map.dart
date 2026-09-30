import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// A stylized, dependency-free stand-in for a real map.
///
/// The tech stack calls for `google_maps_flutter` (see
/// lib/services/location_service.dart for the wiring notes) which needs a
/// Google Maps API key to render real tiles. To keep this project runnable
/// out of the box with no external setup, these screens draw a lightweight
/// street-grid + route mock instead. Swap `MockRouteMap` / `MockPulseMap`
/// for a real `GoogleMap` widget once a key is configured.
class MockRouteMap extends StatelessWidget {
  const MockRouteMap({super.key});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _RouteMapPainter(), child: Container());
  }
}

class MockPulseMap extends StatelessWidget {
  const MockPulseMap({super.key, this.pulseColor = AppColors.redAlert});

  final Color pulseColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _PulseMapPainter(pulseColor), child: Container());
  }
}

class MiniLocationPreview extends StatelessWidget {
  const MiniLocationPreview({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        color: AppColors.tealBg,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.tealPrimary.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.location_on, color: AppColors.tealPrimary),
      ),
    );
  }
}

void _drawGrid(Canvas canvas, Size size) {
  final gridPaint = Paint()
    ..color = const Color(0xFFD6E0E3)
    ..strokeWidth = 1;
  for (double x = 0; x < size.width; x += size.width / 7) {
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
  }
  for (double y = 0; y < size.height; y += size.height / 9) {
    canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
  }
}

class _RouteMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    _drawGrid(canvas, size);

    final start = Offset(size.width * 0.18, size.height * 0.78);
    final bend1 = Offset(size.width * 0.45, size.height * 0.78);
    final bend2 = Offset(size.width * 0.45, size.height * 0.5);
    final end = Offset(size.width * 0.55, size.height * 0.38);

    final routePaint = Paint()
      ..color = AppColors.tealPrimary
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(bend1.dx, bend1.dy)
      ..lineTo(bend2.dx, bend2.dy)
      ..lineTo(end.dx, end.dy);
    canvas.drawPath(path, routePaint);

    canvas.drawCircle(start, 7, Paint()..color = const Color(0xFF9AA9AE));
    canvas.drawCircle(start, 3.5, Paint()..color = Colors.white);

    canvas.drawCircle(end, 34, Paint()..color = AppColors.tealPrimary.withValues(alpha: 0.15));
    canvas.drawCircle(end, 20, Paint()..color = AppColors.tealPrimary.withValues(alpha: 0.25));
    canvas.drawCircle(end, 10, Paint()..color = AppColors.tealPrimary);
    canvas.drawCircle(end, 4, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PulseMapPainter extends CustomPainter {
  _PulseMapPainter(this.pulseColor);
  final Color pulseColor;

  @override
  void paint(Canvas canvas, Size size) {
    _drawGrid(canvas, size);
    final center = Offset(size.width * 0.35, size.height * 0.5);
    canvas.drawCircle(center, 50, Paint()..color = pulseColor.withValues(alpha: 0.12));
    canvas.drawCircle(center, 30, Paint()..color = pulseColor.withValues(alpha: 0.22));
    canvas.drawCircle(center, 11, Paint()..color = pulseColor);
    canvas.drawCircle(center, 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

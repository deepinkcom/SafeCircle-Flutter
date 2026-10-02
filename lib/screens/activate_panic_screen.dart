import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class ActivatePanicScreen extends StatefulWidget {
  const ActivatePanicScreen({super.key, required this.onBack, required this.onAlertSent});

  final VoidCallback onBack;
  final VoidCallback onAlertSent;

  @override
  State<ActivatePanicScreen> createState() => _ActivatePanicScreenState();
}

class _ActivatePanicScreenState extends State<ActivatePanicScreen> {
  static const _totalMs = 3000;
  static const _stepMs = 30;

  Timer? _timer;
  double _progress = 0;
  bool _pressed = false;

  void _startHold() {
    _timer?.cancel();
    setState(() {
      _pressed = true;
      _progress = 0;
    });
    var elapsed = 0;
    _timer = Timer.periodic(const Duration(milliseconds: _stepMs), (t) {
      elapsed += _stepMs;
      setState(() => _progress = (elapsed / _totalMs).clamp(0, 1));
      if (elapsed >= _totalMs) {
        t.cancel();
        widget.onAlertSent();
      }
    });
  }

  void _cancelHold() {
    _timer?.cancel();
    setState(() {
      _pressed = false;
      _progress = 0;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secondsLeft = _pressed ? (3 - (_progress * 3)).ceil().clamp(1, 3) : 3;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back, color: AppColors.navyDark),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Text('Activate Panic Alert',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontSize: 26),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 6),
                    const Text('Help is on the way. Stay calm.',
                        style: TextStyle(color: AppColors.textMuted),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 36),
                    GestureDetector(
                      onTapDown: (_) => _startHold(),
                      onTapUp: (_) => _cancelHold(),
                      onTapCancel: _cancelHold,
                      child: SizedBox(
                        width: 260,
                        height: 260,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CustomPaint(
                              size: const Size(260, 260),
                              painter: _RingPainter(progress: _progress),
                            ),
                            Container(
                              width: 200,
                              height: 200,
                              decoration: const BoxDecoration(
                                  color: AppColors.redAlert, shape: BoxShape.circle),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.warning_rounded, color: Colors.white, size: 30),
                                  const SizedBox(height: 6),
                                  Text(
                                    _pressed ? 'Activating in' : 'Hold to activate',
                                    style: const TextStyle(color: Colors.white, fontSize: 13),
                                    textAlign: TextAlign.center,
                                  ),
                                  Text(
                                    _pressed ? '$secondsLeft' : '',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 40),
                                  ),
                                  const Text('Hold to confirm',
                                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Card(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.location_on, color: AppColors.redAlert),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  RichText(
                                    text: const TextSpan(
                                      style: TextStyle(color: AppColors.navyDark, fontSize: 14),
                                      children: [
                                        TextSpan(
                                            text:
                                                'Your live location will be shared with nearby users within '),
                                        TextSpan(
                                            text: '1 km',
                                            style: TextStyle(
                                                color: AppColors.redAlert,
                                                fontWeight: FontWeight.w700)),
                                        TextSpan(text: '.'),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Emergency contacts and nearby SafeCircle users will be notified immediately.',
                                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: widget.onAlertSent,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.redAlert,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        ),
                        icon: const Icon(Icons.campaign, size: 18),
                        label: const Text('Send Alert Now',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: OutlinedButton(
                        onPressed: widget.onBack,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.tealPrimary),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        ),
                        child: const Text('Cancel',
                            style: TextStyle(
                                color: AppColors.tealPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.verified_user, color: AppColors.tealPrimary, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'False alerts can cause delay in real emergencies. Please activate only if you need help.',
                            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);

    final bgPaint = Paint()
      ..color = AppColors.redAlertLight
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -1.5708, 6.2832, false, bgPaint);

    final fgPaint = Paint()
      ..color = AppColors.redAlert
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -1.5708, 6.2832 * progress, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => oldDelegate.progress != progress;
}

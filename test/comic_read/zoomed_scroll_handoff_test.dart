import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zephyr/page/comic_read/method/zoomed_scroll_handoff.dart';

void main() {
  testWidgets('zoomed vertical drags continue through multiple list images', (
    tester,
  ) async {
    final scroll = ScrollController();
    final transform = TransformationController(
      Matrix4.identity()..scaleByDouble(2, 2, 1, 1),
    );
    final handoff = ZoomedScrollHandoff();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 400,
            child: InteractiveViewer(
              transformationController: transform,
              minScale: 1,
              maxScale: 4,
              onInteractionStart: (_) => handoff.start(transform),
              onInteractionUpdate: (details) => handoff.update(
                details: details,
                transformation: transform,
                scrollController: scroll,
                enabled: true,
              ),
              child: ListView.builder(
                controller: scroll,
                physics: const NeverScrollableScrollPhysics(),
                itemExtent: 400,
                itemCount: 5,
                itemBuilder: (_, index) => ColoredBox(
                  color: index.isEven ? Colors.red : Colors.blue,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final viewer = find.byType(InteractiveViewer);
    for (var i = 0; i < 8; i++) {
      await tester.drag(viewer, const Offset(0, -250));
      await tester.pumpAndSettle();
    }
    // 已越过第一张图，且没有通过缩小来恢复滚动。
    expect(scroll.offset, greaterThan(400));
    expect(transform.value.getMaxScaleOnAxis(), closeTo(2, 0.001));

    for (var i = 0; i < 20; i++) {
      await tester.drag(viewer, const Offset(0, 250));
      await tester.pumpAndSettle();
    }
    expect(scroll.offset, closeTo(0, 0.001));

    // 双指捏合不应被当成列表拖动；横向单页模式也不参与转交。
    for (final enabled in [true, false]) {
      handoff.start(transform);
      handoff.update(
        details: ScaleUpdateDetails(
          focalPointDelta: const Offset(0, -100),
          pointerCount: enabled ? 2 : 1,
        ),
        transformation: transform,
        scrollController: scroll,
        enabled: enabled,
      );
      expect(scroll.offset, 0);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    transform.dispose();
  });
}

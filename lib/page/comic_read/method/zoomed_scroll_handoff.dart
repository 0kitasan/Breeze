import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:zephyr/page/comic_read/widgets/layout/read_layout.dart';

/// 将缩放视口无法继续消耗的纵向拖动交给条漫列表。
///
/// InteractiveViewer 的 child 是列表视口，而不是整章的高度。放大后列表
/// 虽然锁定了自身的拖动识别，仍可通过控制器滚动，继续加载后面的图片。
class ZoomedScrollHandoff {
  double? _previousTranslationY;
  double? _previousScale;

  void start(TransformationController transformation) {
    _previousTranslationY = transformation.value.storage[13];
    _previousScale = transformation.value.getMaxScaleOnAxis();
  }

  void update({
    required ScaleUpdateDetails details,
    required TransformationController transformation,
    required ScrollController scrollController,
    required bool enabled,
  }) {
    final matrix = transformation.value;
    final translationY = matrix.storage[13];
    final scale = matrix.getMaxScaleOnAxis();
    final previousY = _previousTranslationY;
    final previousScale = _previousScale;
    _previousTranslationY = translationY;
    _previousScale = scale;

    // 捏合及缩放锚点变化不应改变列表位置。
    if (!enabled ||
        details.pointerCount != 1 ||
        previousY == null ||
        previousScale == null ||
        (scale - previousScale).abs() > 0.0001 ||
        scale <= kScaleLockThreshold ||
        !scrollController.hasClients) {
      return;
    }

    final dragY = details.focalPointDelta.dy;
    final remainingY = dragY - (translationY - previousY);
    // 仅转交同方向且未被视口消耗的部分，避免边界校正造成反向跳动。
    if (dragY * remainingY <= 0) return;
    final delta = remainingY.abs() > dragY.abs() ? dragY : remainingY;
    final position = scrollController.position;
    final target = (position.pixels - delta / scale)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() > 0.001) {
      scrollController.jumpTo(target);
    }
  }
}

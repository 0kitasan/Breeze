import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:zephyr/page/comic_read/widgets/layout/read_layout.dart';

/// 将缩放视口无法继续消耗的纵向拖动交给条漫列表。
///
/// InteractiveViewer 的 child 是列表视口，而不是整章的高度。放大后列表
/// 虽然锁定了自身的拖动识别，仍可接收转交的拖动及松手速度。
class ZoomedScrollHandoff {
  double? _previousTranslationY;
  double? _previousScale;
  Drag? _drag;
  ScrollPosition? _position;
  double _lastDirection = 0;

  bool get isActive => _drag != null || _position != null;

  void _onScrollActivityChanged() {
    if (_drag == null && _position?.isScrollingNotifier.value == false) {
      _detachPosition();
    }
  }

  void _detachPosition() {
    _position?.isScrollingNotifier.removeListener(_onScrollActivityChanged);
    _position = null;
  }

  void cancel() {
    final position = _position;
    _drag?.cancel();
    _drag = null;
    _detachPosition();
    // 取消本次手势留下的惯性，防止捏合、关开关或切页后继续滑动。
    if (position != null && position.hasPixels) {
      position.jumpTo(position.pixels);
    }
    _lastDirection = 0;
    _previousTranslationY = null;
    _previousScale = null;
  }

  void end(ScaleEndDetails details) {
    final drag = _drag;
    _drag = null;
    if (drag == null) return;
    final scale = _previousScale ?? 1;
    final velocityY = details.velocity.pixelsPerSecond.dy;
    final canFling = details.pointerCount == 0 &&
        velocityY * _lastDirection > 0;
    drag.end(DragEndDetails(
      velocity: Velocity(pixelsPerSecond: Offset(0, canFling ? velocityY / scale : 0)),
      primaryVelocity: canFling ? velocityY / scale : 0,
    ));
    _onScrollActivityChanged();
  }

  void start(TransformationController transformation) {
    cancel();
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
      cancel();
      _previousTranslationY = translationY;
      _previousScale = scale;
      return;
    }

    final dragY = details.focalPointDelta.dy;
    final remainingY = dragY - (translationY - previousY);
    // 仅转交同方向且未被视口消耗的部分，避免边界校正造成反向跳动。
    if (dragY * remainingY <= 0) return;
    final delta = remainingY.abs() > dragY.abs() ? dragY : remainingY;
    if (delta.abs() < 0.001) return;
    final position = scrollController.position;
    final target = (position.pixels - delta / scale)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 0.001) return;
    if (_drag == null) {
      _detachPosition();
      _position = position;
      position.isScrollingNotifier.addListener(_onScrollActivityChanged);
      _drag = position.drag(
        DragStartDetails(globalPosition: details.focalPoint),
        () {
          // end() 已将 _drag 清空时，继续跟踪松手后的惯性直到停止。
          if (_drag != null) {
            _drag = null;
            _detachPosition();
          }
        },
      );
    }
    _lastDirection = delta;
    _drag!.update(DragUpdateDetails(
      globalPosition: details.focalPoint,
      delta: Offset(0, position.pixels - target),
      primaryDelta: position.pixels - target,
    ));
  }
}

import 'package:window_manager/window_manager.dart';

/// 应用主窗口句柄的缓存。
///
/// window_manager 0.7 起窗口操作都挂在 [Window] 实例上，而
/// `WindowManager.instance.getCurrent()` 每次调用都会新建一个句柄对象，
/// 因此这里只查询一次并复用，避免频繁 FFI 调用与句柄对象堆积。
Window? _mainWindow;

/// 当前应用主窗口；窗口尚未创建时返回 null。
Window? get mainWindow {
  final cached = _mainWindow;
  if (cached != null) return cached;
  return _mainWindow = WindowManager.instance.getCurrent();
}

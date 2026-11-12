import 'package:window_manager/window_manager.dart';

/// 应用主窗口句柄的缓存。
///
/// window_manager 0.7 起窗口操作都挂在 [Window] 实例上，而
/// `WindowManager.instance.getCurrent()` 每次调用都会新建一个句柄对象，
/// 因此这里只查询一次并复用，避免频繁 FFI 调用与句柄对象堆积。
Window? _mainWindow;

/// 当前应用主窗口；窗口尚未创建时返回 null。
///
/// `getCurrent()` 取的是“当前/关键窗口”，而 macOS runner 会在启动时先把窗口
/// 隐藏起来（等 Dart 侧摆好尺寸/位置再 show），此时窗口不是 key window，
/// `getCurrent()` 可能返回 null。这种情形退回应用自己的第一个窗口——
/// 启动阶段本应用只有主窗口这一个原生窗口。
Window? get mainWindow {
  final cached = _mainWindow;
  if (cached != null) return cached;
  final current = WindowManager.instance.getCurrent();
  if (current != null) return _mainWindow = current;
  final windows = WindowManager.instance.getAll();
  if (windows.isEmpty) return null;
  return _mainWindow = windows.first;
}

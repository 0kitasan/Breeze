import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 启动时是否已经隐藏过一次窗口。
  ///
  /// window_manager 0.7 起插件不再自带 macOS 原生代码（原来的
  /// `NSWindow.hiddenWindowAtLaunch()` 扩展随之消失），这里内联它原本的行为：
  /// nib 在启动时会 order 一次窗口，此时立刻隐藏，等 Dart 侧
  /// `WindowLogic.initWindow` 摆好尺寸/位置后调用 `show()` 再显示，
  /// 避免启动瞬间出现默认尺寸的窗口闪烁跳动。
  private var didHideAtLaunch = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    if !didHideAtLaunch {
      didHideAtLaunch = true
      setIsVisible(false)
    }
  }
}

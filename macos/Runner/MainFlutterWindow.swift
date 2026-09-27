import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    let visibleSize = (self.screen ?? NSScreen.main)?.visibleFrame.size
    let targetSize = NSSize(
      width: min(1100, (visibleSize?.width ?? 1200) * 0.9),
      height: min(760, (visibleSize?.height ?? 900) * 0.9)
    )
    self.minSize = NSSize(
      width: min(960, targetSize.width),
      height: min(640, targetSize.height)
    )
    self.setContentSize(targetSize)
    self.center()
  }
}

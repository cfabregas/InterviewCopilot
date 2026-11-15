import AppKit
import ScreenCaptureKit

/// 用 ScreenCaptureKit 截一帧主屏幕，检查悬浮窗的品红标记是否入画。
/// 会议软件的屏幕共享大多走同一套采集管线，所以这是一个客观的近似检测；
/// 最终结论仍以在各会议软件里实际共享为准。
enum CaptureCheck {
    struct Result {
        let listedInShareableContent: Bool   // 悬浮窗是否出现在可共享窗口列表里
        let markerVisible: Bool              // 截屏里是否能看到标记
        let pixel: (r: UInt8, g: UInt8, b: UInt8)
    }

    @MainActor
    static func run(panel: OverlayPanel) async throws -> Result {
        let center = panel.markerCenterOnScreen
        let screenFrame = NSScreen.screens[0].frame
        let windowID = CGWindowID(panel.windowNumber)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw ProbeError("找不到显示器")
        }
        let listed = content.windows.contains { $0.windowID == windowID }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let scale = CGFloat(image.width) / screenFrame.width
        let x = Int((center.x - screenFrame.minX) * scale)
        let y = Int((screenFrame.height - (center.y - screenFrame.minY)) * scale)
        guard let px = pixel(image, x: x, y: y) else {
            throw ProbeError("标记不在主屏幕范围内，请把悬浮窗拖回主屏幕")
        }
        let visible = px.r > 200 && px.g < 80 && px.b > 200
        return Result(listedInShareableContent: listed, markerVisible: visible, pixel: px)
    }

    /// 读取图像中 (x, y) 处的像素，y 从顶部算起
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }
}

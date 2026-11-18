// 把 AppIcon.svg 渲染成 macOS 需要的各个尺寸，打包成 AppIcon.icns。
// 改了 SVG 之后运行：swift Assets/make-icon.swift
import AppKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
guard let svg = NSImage(contentsOf: dir.appendingPathComponent("AppIcon.svg")) else {
    fatalError("读不了 AppIcon.svg")
}
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int, to name: String, in folder: URL = iconset) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try render(size, to: "icon_\(size)x\(size).png")
    try render(size * 2, to: "icon_\(size)x\(size)@2x.png")
}
try render(1024, to: "AppIcon-1024.png", in: dir)   // README 用的大图

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "已生成 AppIcon.icns" : "iconutil 失败")

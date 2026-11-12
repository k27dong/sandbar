import AppKit
import SwiftUI
import Testing

@MainActor enum Pictures {
    static func draw(_ view: some View, named name: String, dark: Bool = false) throws -> URL {
        _ = NSApplication.shared  // a test process has no application until asked, and a window needs one
        let host = NSHostingView(
            rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.displayScale, 2))
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        let size = host.bounds.size
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))

        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SANDBAR_PICTURES"] ?? ".build/pictures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try png.write(to: file)
        return file
    }
}

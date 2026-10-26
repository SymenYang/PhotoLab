import AppKit

@main struct GestureTests {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { print("FAIL: " + message); fflush(stdout); throw CatalogError(message: message) }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = PhotoScroll(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true; scroll.minMagnification = 1; scroll.maxMagnification = 8
        scroll.documentView = scroll.picture
        scroll.picture.image = NSImage(size: NSSize(width: 9000, height: 6000))
        window.contentView = scroll
        var requestedEdges = [Int]()
        scroll.onPreviewSize = { requestedEdges.append($0) }
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try check(!requestedEdges.isEmpty, "missing initial resolution request")
        let fittedEdge = requestedEdges.last!
        let fittedSize = scroll.picture.frame.size
        scroll.setMagnification(2, centeredAt: NSPoint(x: 450, y: 300))
        scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        try check(scroll.picture.frame.size == fittedSize, "pinch resized fitted document")
        try check(abs(scroll.contentView.bounds.width - fittedSize.width / 2) < 2, "pinch failed to magnify viewport")
        try await Task.sleep(for: .milliseconds(50))
        try check(requestedEdges.last! >= fittedEdge * 2 - 128, "pinch did not request higher resolution")
        let before = scroll.contentView.bounds.origin
        let target = NSRect(origin: NSPoint(x: before.x + 50, y: before.y + 40), size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(target).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        try check(scroll.contentView.bounds.origin.x > before.x + 40 && scroll.contentView.bounds.origin.y > before.y + 30, "layout reset panning")
        let zoomedOrigin = scroll.contentView.bounds.origin
        scroll.picture.image = NSImage(size: NSSize(width: 9000, height: 6000))
        scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        try check(scroll.magnification == 2 && scroll.contentView.bounds.origin == zoomedOrigin, "preview replacement reset viewport")
        scroll.magnification = 4
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try check(requestedEdges.last! >= (fittedEdge - 128) * 4, "direct magnification did not refresh preview: edges \(requestedEdges), magnification \(scroll.magnification), frame \(scroll.contentView.frame), content \(scroll.contentSize)")
        scroll.picture.rotation = 1; scroll.recenter = true; scroll.magnification = 1
        scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        scroll.setMagnification(3, centeredAt: NSPoint(x: 450, y: 300))
        scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
        try check(scroll.magnification == 3 && scroll.picture.frame.size == fittedSize, "rotated pinch failed")
        print("PASS native magnification, two-axis viewport panning, layout persistence, rotated image")
    }
}

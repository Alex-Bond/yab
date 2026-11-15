import AppKit

/// Full-page captures use the same screen renderer as visible captures.
/// PDF export has a different paint path (filters, masks and layers differ).
@MainActor
enum CapturePage {
    struct Result {
        let image: CGImage
        let secrets: [CGRect]
    }

    /// `rect` is relative to the current viewport, in view points. Never
    /// resize the view: doing so changes vh units and responsive layouts.
    static func take(_ web: any PageHandle, rect: CGRect, pixelWidth: Int, zoom: CGFloat,
                     valid: @escaping @MainActor () -> Bool) async -> Result? {
        let token = UUID().uuidString
        do {
            let initial = try await web.call(prepare, arguments: ["token": token], in: .yab) as? [String: Any]
            guard let initial,
                  let x = initial["x"] as? Double, let y = initial["y"] as? Double,
                  let w = initial["w"] as? Double, let h = initial["h"] as? Double,
                  x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0, zoom.isFinite, zoom > 0,
                  rect.size.width.isFinite, rect.size.height.isFinite,
                  rect.size.width > 0, rect.size.height > 0, pixelWidth > 0 else { throw PageShotFailed() }
            let document = rect.offsetBy(dx: x * zoom, dy: y * zoom)
            // innerWidth/Height can round CSS pixels at fractional zoom.
            let viewport = CGSize(width: min(web.bounds.width, w * zoom), height: min(web.bounds.height, h * zoom))
            guard viewport.width > 0, viewport.height > 0 else { throw PageShotFailed() }
            let scale = CGFloat(pixelWidth) / rect.width
            let pixelHeight = (rect.height * scale).rounded()
            guard pixelHeight.isFinite, pixelHeight > 0,
                  Double(pixelWidth) * pixelHeight <= Double(Capture.most) + Double(pixelWidth),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(data: nil, width: pixelWidth, height: Int(pixelHeight), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw PageShotFailed() }
            let columns = ceil(document.width / viewport.width), rows = ceil(document.height / viewport.height)
            guard columns * rows <= 512 else { throw PageShotFailed() }
            var secrets: [CGRect] = []
            var index = 0
            for row in 0..<Int(rows) {
                for column in 0..<Int(columns) {
                    guard valid(), !Task.isCancelled else { throw CancellationError() }
                    let left = document.minX + CGFloat(column) * viewport.width
                    let top = document.minY + CGFloat(row) * viewport.height
                    let tile = CGRect(x: left, y: top, width: min(viewport.width, document.maxX - left),
                                      height: min(viewport.height, document.maxY - top))
                    let position = try await web.call(move, arguments: ["token": token, "x": left / zoom,
                                                                        "y": top / zoom, "first": index == 0 && document.minY <= 0], in: .yab) as? [String: Any]
                    guard valid(), let position, let sx = position["x"] as? Double, let sy = position["y"] as? Double,
                          position["w"] as? Double == w, position["h"] as? Double == h else { throw PageShotFailed() }
                    let source = tile.offsetBy(dx: -sx * zoom, dy: -sy * zoom)
                    guard CGRect(origin: .zero, size: viewport).insetBy(dx: -0.5, dy: -0.5).contains(source)
                    else { throw PageShotFailed() }
                    // Find secrets in every painted tile, including virtualized
                    // content that did not exist at the original scroll position.
                    let boxes = try await web.run("window.__yabCapture.secrets(\(source.minX / zoom),\(source.minY / zoom),\(source.width / zoom),\(source.height / zoom))", in: .yab)
                    secrets += (boxes as? [Any] ?? []).compactMap(CaptureBox.init).map {
                        $0.rect.applying(.init(scaleX: zoom, y: zoom))
                            .offsetBy(dx: tile.minX - document.minX, dy: tile.minY - document.minY)
                    }
                    let picture = try await web.snapshot(PageShot(rect: source, width: source.width * scale / (web.window?.backingScaleFactor ?? 1)))
                    guard valid(), try await web.call("return window.__yabCaptureTiles?.token === token", arguments: ["token": token], in: .yab) as? Bool == true,
                          let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PageShotFailed() }
                    // Round shared edges, rather than each tile's height, so
                    // fractional zoom and downscaling cannot leave seam pixels.
                    let x0 = ((tile.minX - document.minX) * scale).rounded()
                    let x1 = ((tile.maxX - document.minX) * scale).rounded()
                    let y0 = ((tile.minY - document.minY) * scale).rounded()
                    let y1 = ((tile.maxY - document.minY) * scale).rounded()
                    canvas.draw(image, in: CGRect(x: x0, y: pixelHeight - y1, width: x1 - x0, height: y1 - y0))
                    index += 1
                }
            }
            guard let image = canvas.makeImage() else { throw PageShotFailed() }
            let restored = (try? await web.call(restore, arguments: ["token": token], in: .yab)) as? Bool
            return restored == true && valid() ? Result(image: image, secrets: secrets) : nil
        } catch {
            // Also restore after cancellation, a failed snapshot, or navigation.
            // The token prevents touching a replacement document/capture.
            _ = try? await web.call(restore, arguments: ["token": token], in: .yab)
            return nil
        }
    }

    static let prepare = #"""
    if (window.__yabCaptureTiles) throw new Error('Capture already running');
    const state = {token, x: scrollX, y: scrollY, records: [], fixed: new Set(), seen: new WeakSet()};
    window.__yabCaptureTiles = state;
    state.finish = () => {
      for (const [node, property, value, priority] of state.records.reverse()) {
        if (value) node.style.setProperty(property, value, priority);
        else node.style.removeProperty(property);
      }
      window.scrollTo(state.x, state.y);
      state.style.remove();
      removeEventListener('pagehide', state.finish);
      delete window.__yabCaptureTiles;
    };
    state.change = (node, property, value) => {
      state.records.push([node, property, node.style.getPropertyValue(property), node.style.getPropertyPriority(property)]);
      node.style.setProperty(property, value, 'important');
    };
    state.scan = first => {
      for (const node of document.querySelectorAll('*')) {
        if (state.seen.has(node)) continue;
        state.seen.add(node);
        const position = getComputedStyle(node).position;
        if (position === 'sticky') {
          state.change(node, 'position', 'relative');
          for (const edge of ['top','right','bottom','left']) state.change(node, edge, 'auto');
        } else if (position === 'fixed') state.fixed.add(node);
      }
      if (!first) for (const node of state.fixed) {
        if (getComputedStyle(node).visibility !== 'hidden') state.change(node, 'visibility', 'hidden');
      }
    };
    state.style = document.createElement('style');
    state.style.textContent = '* {scroll-behavior:auto!important;scroll-snap-type:none!important;overflow-anchor:none!important}';
    document.documentElement.appendChild(state.style);
    // A document kept in the back/forward cache must not retain our styles.
    addEventListener('pagehide', state.finish, {once:true});
    return {x: state.x, y: state.y, w: innerWidth, h: innerHeight};
    """#

    static let move = #"""
    const state = window.__yabCaptureTiles;
    if (!state || state.token !== token) throw new Error('Capture ended');
    state.scan(first);
    window.scrollTo(x, y);
    await new Promise(resolve => {
      const timer = setTimeout(resolve, 100);
      requestAnimationFrame(() => requestAnimationFrame(() => {clearTimeout(timer); resolve();}));
    });
    state.scan(first);
    return {x: scrollX, y: scrollY, w: innerWidth, h: innerHeight};
    """#

    static let restore = #"""
    const state = window.__yabCaptureTiles;
    if (!state || state.token !== token) return false;
    // Restore while smooth scrolling and snapping are still disabled.
    state.finish();
    return true;
    """#
}

import AppKit

/// Geometry and identity for engine-neutral parity probes. No WebKit cast.
@MainActor enum ChromiumParityBench {
    static func describe(_ tab: Tab) -> [String: Any] {
        let page = tab.page
        var result: [String: Any] = ["engine": tab.engineKind.rawValue,
                                    "builtEngine": page.engine.rawValue,
                                    "title": page.title ?? "", "loading": page.isLoading,
                                    "window": page.window?.windowNumber ?? 0]
        if let chromium = page as? ChromiumPage {
            result["pressureBehavior"] = chromium.pressureConfiguration?.pressureBehavior.rawValue ?? -1
            result["forceReleases"] = chromium.forceInput.releaseCount
        }
        if let content = page.window?.contentView {
            let rect = page.convert(page.bounds, to: content)
            result["contentSize"] = [content.bounds.width, content.bounds.height]
            result["pageRect"] = [rect.minX, content.isFlipped ? rect.minY : content.bounds.height - rect.maxY,
                                  rect.width, rect.height]
        }
        return result
    }
}

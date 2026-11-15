import Foundation

enum AgentCoordinates {
    /// MCP screenshots are 1024 pixels wide. Mouse events use unzoomed
    /// view coordinates; reject points outside the photographed viewport.
    static func point(x: Double, y: Double, size: CGSize, zoom: Double) -> CGPoint? {
        guard x.isFinite, y.isFinite, zoom.isFinite, zoom > 0,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, x >= 0, y >= 0,
              x < 1024, y < Double(size.height / size.width) * 1024 else { return nil }
        let scale = Double(size.width) / 1024 / zoom
        return CGPoint(x: x * scale, y: y * scale)
    }
}

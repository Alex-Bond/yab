import SwiftUI

/// Shared by tab titles in the column and the strip, their drag previews,
/// and native editing fields.
private struct TabTitleSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 12.5
}

extension EnvironmentValues {
    var tabTitleSize: CGFloat {
        get { self[TabTitleSizeKey.self] }
        set { self[TabTitleSizeKey.self] = newValue }
    }
}

struct SidebarTypography: ViewModifier {
    @Environment(\.sidebarRowSize) private var rowSize

    static func titleSize(for rowSize: SidebarRowSize) -> CGFloat {
        switch rowSize {
        case .small: 13
        case .medium: 14
        case .large: 16
        @unknown default: 14
        }
    }

    func body(content: Content) -> some View {
        content.environment(\.tabTitleSize, Self.titleSize(for: rowSize))
    }
}

extension SidebarTypography {
    /// The tab title's size where no view environment reaches: metrics
    /// worked out ahead of drawing, as the corner's notice does. The same
    /// system setting (Appearance › Sidebar icon size), read from defaults.
    static var current: CGFloat {
        switch UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode") {
        case 1: titleSize(for: .small)
        case 3: titleSize(for: .large)
        default: titleSize(for: .medium)
        }
    }
}

/// Keep the address and preview text hierarchy while following the same
/// system preference as tab titles. Read it here so separate popovers also
/// update without inheriting the sidebar's view environment.
private struct SidebarFont: ViewModifier {
    @Environment(\.sidebarRowSize) private var rowSize
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * SidebarTypography.titleSize(for: rowSize) / 14,
                             weight: weight, design: design))
    }
}

extension View {
    func sidebarFont(size: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> some View {
        modifier(SidebarFont(size: size, weight: weight, design: design))
    }
}

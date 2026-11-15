import Foundation

/// The icons a space can wear instead of an emoji, as Arc's Icon tab
/// offers them (eight across, seven down): SF Symbols, kept in a space's
/// `icon` by name. An emoji is never plain letters, a symbol's name always
/// is. Each has the emoji an iPhone shows for it, which draws emoji only.
public enum SpaceSymbols {
    public static let all: [(symbol: String, emoji: String)] = [
        ("star.fill", "⭐️"), ("bookmark.fill", "🔖"), ("heart.fill", "❤️"), ("flag.fill", "🚩"),
        ("bolt.fill", "⚡️"), ("triangle.fill", "🔺"), ("asterisk", "✳️"), ("bell.fill", "🔔"),
        ("lightbulb.fill", "💡"), ("square.on.circle.fill", "🔷"), ("square.grid.2x2.fill", "🔲"), ("circle.grid.3x3.fill", "🎲"),
        ("square.3.layers.3d", "🥞"), ("cylinder.fill", "🗄️"), ("rectangle.stack.fill", "🗂️"), ("square.fill.on.square.fill", "📑"),
        ("folder.fill", "📁"), ("tray.fill", "📥"), ("calendar", "📅"), ("envelope.fill", "✉️"),
        ("checkmark.square.fill", "✅"), ("doc.fill", "📄"), ("book.fill", "📖"), ("ellipsis.bubble.fill", "💬"),
        ("person.2.fill", "👥"), ("apple.terminal.fill", "💻"), ("wrench.and.screwdriver.fill", "🛠️"), ("square.fill", "⬛️"),
        ("oval.portrait.fill", "🥚"), ("circle.fill", "⚫️"), ("moon.fill", "🌙"), ("sun.max.fill", "☀️"),
        ("globe.americas.fill", "🌎"), ("leaf.fill", "🍃"), ("cloud.fill", "☁️"), ("pawprint.fill", "🐾"),
        ("basket.fill", "🧺"), ("gift.fill", "🎁"), ("bed.double.fill", "🛏️"), ("fork.knife", "🍴"),
        ("dumbbell.fill", "🏋️"), ("airplane", "✈️"), ("music.note", "🎵"), ("paintpalette.fill", "🎨"),
        ("video.fill", "🎥"), ("bandage.fill", "🩹"), ("chevron.left.forwardslash.chevron.right", "⌨️"), ("baseball.fill", "⚾️"),
        ("cloud", "🌥️"), ("map.fill", "🗺️"), ("flame.fill", "🔥"), ("cup.and.saucer.fill", "☕️"),
        ("theatermasks.fill", "🎭"), ("scroll.fill", "📜"), ("hand.thumbsup.fill", "👍"), ("tram.fill", "🚆"),
    ]

    /// A symbol's name, not an emoji.
    public static func isSymbol(_ icon: String) -> Bool { !icon.isEmpty && icon.allSatisfy(\.isASCII) }

    /// What a device that draws only emoji writes back for a space that
    /// wears `synced`: the symbol it was sent while `shown` is still that
    /// symbol's emoji, the emoji only once one was picked there. Written
    /// as the emoji, the Mac's symbol turned into its twin (feedback #354).
    public static func wire(shown: String, synced: String) -> String {
        isSymbol(synced) && emoji(synced) == shown ? synced : shown
    }

    /// Keep a symbol over its unchosen emoji echo. A Mac can echo an old
    /// phone's value too, so the writer's device type proves no intent.
    /// A matching explicit choice lets a deliberate twin emoji pick in;
    /// a stale choice for another value cannot authorize an echo.
    public static func kept(incoming: String, had: String, choice: String? = nil) -> String {
        if choice == incoming { return incoming }
        return isSymbol(had) && !isSymbol(incoming) && emoji(had) == incoming ? had : incoming
    }

    /// What a space shows where only emoji are drawn: its emoji, or its
    /// symbol's.
    public static func emoji(_ icon: String) -> String {
        guard isSymbol(icon) else { return icon }
        return all.first { $0.symbol == icon }?.emoji ?? "📁"
    }
}

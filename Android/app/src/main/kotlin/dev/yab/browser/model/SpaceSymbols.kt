package dev.yab.browser.model

/** Current SyncKit SpaceSymbols.swift. Display conversion never changes the saved wire icon. */
internal object SpaceSymbols {
    private val symbols = linkedMapOf(
        "star.fill" to "⭐️",
        "bookmark.fill" to "🔖",
        "heart.fill" to "❤️",
        "flag.fill" to "🚩",
        "bolt.fill" to "⚡️",
        "triangle.fill" to "🔺",
        "asterisk" to "✳️",
        "bell.fill" to "🔔",
        "lightbulb.fill" to "💡",
        "square.on.circle.fill" to "🔷",
        "square.grid.2x2.fill" to "🔲",
        "circle.grid.3x3.fill" to "🎲",
        "square.3.layers.3d" to "🥞",
        "cylinder.fill" to "🗄️",
        "rectangle.stack.fill" to "🗂️",
        "square.fill.on.square.fill" to "📑",
        "folder.fill" to "📁",
        "tray.fill" to "📥",
        "calendar" to "📅",
        "envelope.fill" to "✉️",
        "checkmark.square.fill" to "✅",
        "doc.fill" to "📄",
        "book.fill" to "📖",
        "ellipsis.bubble.fill" to "💬",
        "person.2.fill" to "👥",
        "apple.terminal.fill" to "💻",
        "wrench.and.screwdriver.fill" to "🛠️",
        "square.fill" to "⬛️",
        "oval.portrait.fill" to "🥚",
        "circle.fill" to "⚫️",
        "moon.fill" to "🌙",
        "sun.max.fill" to "☀️",
        "globe.americas.fill" to "🌎",
        "leaf.fill" to "🍃",
        "cloud.fill" to "☁️",
        "pawprint.fill" to "🐾",
        "basket.fill" to "🧺",
        "gift.fill" to "🎁",
        "bed.double.fill" to "🛏️",
        "fork.knife" to "🍴",
        "dumbbell.fill" to "🏋️",
        "airplane" to "✈️",
        "music.note" to "🎵",
        "paintpalette.fill" to "🎨",
        "video.fill" to "🎥",
        "bandage.fill" to "🩹",
        "chevron.left.forwardslash.chevron.right" to "⌨️",
        "baseball.fill" to "⚾️",
        "cloud" to "🌥️",
        "map.fill" to "🗺️",
        "flame.fill" to "🔥",
        "cup.and.saucer.fill" to "☕️",
        "theatermasks.fill" to "🎭",
        "scroll.fill" to "📜",
        "hand.thumbsup.fill" to "👍",
        "tram.fill" to "🚆"
    )
    fun isSymbol(icon: String): Boolean = icon.isNotEmpty() && icon.all { it.code < 128 }
    fun emoji(icon: String): String = if (isSymbol(icon)) symbols[icon] ?: "📁" else icon
    fun wire(shown: String, synced: String): String = if (isSymbol(synced) && emoji(synced) == shown) synced else shown
    fun kept(incoming: String, had: String, choice: String? = null): String = when {
        choice == incoming -> incoming
        isSymbol(had) && !isSymbol(incoming) && emoji(had) == incoming -> had
        else -> incoming
    }
}

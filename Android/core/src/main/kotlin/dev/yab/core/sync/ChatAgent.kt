package dev.yab.core.sync

/** Current SyncKit ChatAgent v1 wire names. Unknown agents never select a default. */
enum class ChatAgent(val wire: String, val plan: String) {
    CLAUDE("claude", "Claude"),
    CODEX("codex", "ChatGPT"),
    CURSOR("cursor", "Cursor"),
    GEMINI("gemini", "Gemini");

    companion object {
        const val VERSION = 1
        fun fromWire(value: String?): ChatAgent? = entries.firstOrNull { it.wire == value }
    }
}

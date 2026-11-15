import Foundation
import SyncKit

// Stand-ins for the Mac app's types that SyncShapes.swift and SyncChats.swift
// read, with the same fields and the same JSON (Spaces.swift, Live.swift,
// Bookmarks.swift, History.swift, Routines.swift, Chat.swift, ChatItem.swift,
// DiaryPage.swift). Enough to run the Mac's own record
// functions here, unchanged, beside the iPhone's.

struct Space: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var ownSignIns: Bool
    var paint: SpacePaint? = nil
    var origin: String? = nil
    var brought: [String]? = nil
    var signedInAs: String? = nil
}

struct SpacePaint: Codable, Equatable {
    var swatch: String
    var color: String
    var grain: Double
    var colors: [String]
    var transparency: Double

    init(swatch: String, color: String, grain: Double, colors: [String] = [], transparency: Double = 0) {
        self.swatch = swatch; self.color = color; self.grain = grain; self.colors = colors; self.transparency = transparency
    }

    private enum CodingKeys: String, CodingKey { case swatch, color, grain, grainAmount, colors, transparency }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        swatch = try c.decode(String.self, forKey: .swatch)
        color = try c.decode(String.self, forKey: .color)
        transparency = try c.decodeIfPresent(Double.self, forKey: .transparency) ?? 0
        let on = try c.decodeIfPresent(Bool.self, forKey: .grain) ?? false
        grain = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? (on ? 0.35 : 0)
        colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(swatch, forKey: .swatch)
        try c.encode(color, forKey: .color)
        try c.encode(grain > 0, forKey: .grain)
        try c.encode(grain, forKey: .grainAmount)
        try c.encode(transparency, forKey: .transparency)
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
    }
}

struct Live: Codable, Equatable {
    var source = "github.pulls"
    var host = "github.com"
    var show: [String] = ["review", "mine"]
    var hidden: [String] = []
    var query: String? = nil
}

struct LiveMark: Codable, Equatable {
    var key: String
    var words: String?
    var seen: String?
    var folder: UUID?
    var yours: Bool? = nil
    var came: Date? = nil
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String?
    var children: [Bookmark]?
    var added: Date?
    var isFolder: Bool { url == nil }
}

struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
    var typed: Int?
}

struct Routine: Codable, Identifiable, Equatable {
    let id: String
    var when = "daily"
    var prompt = ""
    var last: Date?
    var said: String?
    var session: String?
    var chat: String? = nil
    var found: Int? = nil
    var ended: Date? = nil
    var runsOn: String? = nil
}

enum DiaryPage {
    static let scheme = "yab"
}

struct ChatItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case asked, message, thinking, tool, command, edit, plan, subagent, chose }
    enum State: String, Codable { case running, done, failed }
    let id: String
    var kind: Kind
    var name = ""
    var detail = ""
    var text = ""
    var state = State.running
    var began: Date?
    var ended: Date?
}

struct Chat: Equatable {
    let id: String
    var title: String
    var cli: String
    var model: String?
    var items: [ChatItem]
    var pinned = false
    var archived: Bool?
    var unread: Bool?
    var state: String
    var answer: String
    var started: Date
    var updated: Date
}

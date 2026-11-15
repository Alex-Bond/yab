import AppKit
import SwiftUI

/// Each bot's own mascot: the picture on white fills a
/// round badge, which stays legible in either appearance.
struct AssistantBotIcon: View {
    let client: String
    var side: CGFloat = 28

    private var artwork: NSImage? { AssistantBotArtwork.images[client.lowercased()] }

    var body: some View {
        if client.lowercased() == "cursor" {
            AgentMark(cli: "cursor", side: side)
                .accessibilityHidden(true)
        } else {
            botMark
        }
    }

    private var botMark: some View {
        Circle()
            .fill(.white)
            .overlay {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: side, height: side)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: side * 0.4, weight: .medium))
                        .foregroundStyle(.black)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.07), lineWidth: 0.5))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

private enum AssistantBotArtwork {
    static let images: [String: NSImage] = {
        let names = ["dots", "muse", "grok-bot"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "AssistantIcons"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (name, image)
        })
    }()
}

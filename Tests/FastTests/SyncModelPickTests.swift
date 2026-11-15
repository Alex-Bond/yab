import Foundation
import SyncKit
import Testing
@testable import Fast

/// A chat's model and effort picked on the iPhone (ModelPick): the list a
/// Mac publishes, a chat's head, and words that carry a pick.
@MainActor
struct SyncModelPickTests {
    private let models = [
        SyncMacModel(cli: "claude", model: "opus", name: "Claude Opus", about: "For long, hard tasks.",
                     efforts: ["low", "medium", "high", "xhigh", "max"]),
        SyncMacModel(cli: "codex", model: "gpt-6", name: "GPT-6", about: "", efforts: ["low", "medium", "high"]),
    ]

    @Test func theMacPublishesItsModels() throws {
        let fields = SyncChats.capability(device: "mac", models: models)
        let record = Record(collection: OpenOnMac.capability, id: "mac", fields: fields)
        #expect(ModelPick.supports(record, device: "mac"))
        #expect(ModelPick.models(record, device: "mac") == models)
        let first = try #require(fields[ModelPick.modelsField]?.array?.first?.object)
        #expect(first["cli"]?.string == "claude" && first["model"]?.string == "opus" && first["name"]?.string == "Claude Opus")
        #expect(first["efforts"]?.array?.compactMap(\.string) == ["low", "medium", "high", "xhigh", "max"])
        // Another Mac's record, or one without models, offers no pick.
        #expect(!ModelPick.supports(record, device: "other"))
        let none = Record(collection: OpenOnMac.capability, id: "mac", fields: SyncChats.capability(device: "mac"))
        #expect(!ModelPick.supports(none, device: "mac") && ModelPick.models(none, device: "mac").isEmpty)
        // A row that isn't a model of a known agent is skipped.
        #expect(SyncMacModel(.object(["cli": "mac", "model": "x"])) == nil)
        #expect(SyncMacModel.plan("claude") == "Claude" && SyncMacModel.plan("codex") == "ChatGPT")
        #expect(SyncMacModel.effortTitle("xhigh") == "Extra high" && SyncMacModel.effortTitle("low") == "Low")
        #expect(SyncMacModel.effortTitle("max") == AgentModels.effortTitle("max"))
    }

    @Test func theOfferedListIsThePickersOwn() {
        let every = SyncChats.every()
        for model in AgentModels.claude {
            #expect(every.contains(SyncMacModel(cli: "claude", model: model.model, name: model.name, about: model.about, efforts: model.efforts)))
        }
        #expect(SyncChats.offered().allSatisfy { every.contains($0) })
    }

    @Test func aChatsHeadSaysItsEffort() throws {
        var chat = SyncChat(id: "a:x", device: "mac", title: "T", state: "done", answer: "", cli: "codex", model: "gpt-6",
                            started: 1, updated: 2)
        #expect(chat.fields["effort"] == nil)
        chat.effort = "high"
        let read = try #require(SyncChat(Record(collection: SyncCollection.chat, id: chat.id, fields: chat.fields)))
        #expect(read.cli == "codex" && read.model == "gpt-6" && read.effort == "high")
    }

    @Test func wordsCarryAPick() throws {
        let fields = SyncSend.fields(device: "mac", chat: "a:one", text: "Go", choice: nil, kind: nil, project: nil, at: 1,
                                     model: "opus", effort: "max")
        let record = Record(collection: SyncChats.send, id: "s", fields: fields)
        let words = try #require(SyncChats.waiting([record], device: "mac").first)
        #expect(words.model == "opus" && words.effort == "max")
        #expect(SyncSend(record)?.model == "opus" && SyncSend(record)?.effort == "max")
        #expect(ChatCommand.refusal(record) == nil)
        let plain = SyncSend.fields(device: "mac", chat: "a:one", text: "Go", choice: nil, kind: nil, project: nil, at: 1)
        #expect(plain["model"] == nil && plain["effort"] == nil)
    }

    @Test func aPickIsFittedToWhatTheMacHas() {
        // Known model and effort: as picked; the model names its agent.
        #expect(SyncChats.fit(cli: nil, model: "gpt-6", effort: "high", among: models) == ("codex", "gpt-6", "high"))
        // An effort the model lacks: the most it takes short of it.
        #expect(SyncChats.fit(cli: "codex", model: "gpt-6", effort: "max", among: models) == ("codex", "gpt-6", "high"))
        #expect(SyncChats.fit(cli: "codex", model: "gpt-6", effort: "bogus", among: models) == ("codex", "gpt-6", nil))
        // An unknown model, or one of another agent: the chat keeps its own.
        #expect(SyncChats.fit(cli: "claude", model: "nope", effort: "high", among: models) == ("claude", nil, "high"))
        #expect(SyncChats.fit(cli: "claude", model: "gpt-6", effort: nil, among: models) == ("claude", nil, nil))
        #expect(SyncChats.fit(cli: nil, model: "nope", effort: "high", among: models) == (nil, nil, nil))
    }

    @Test func aPickForAChatThisMacDoesntHaveStillFailsAsBefore() {
        let words = SyncChats.Words(id: "s", chat: "a:missing-\(UUID().uuidString)", text: "Go", kind: "agent", project: nil,
                                    choice: nil, at: Date(), model: "opus", effort: "high")
        #expect(SyncCenter().say(words).reason == "That chat isn't on this Mac any more.")
    }
}

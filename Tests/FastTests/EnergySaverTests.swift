import Foundation
import Testing
@testable import Fast

/// Settings › Tabs › Energy Saver (#2677): Chrome's three states, off unless
/// the person picks one, Chromium's own rule for when it holds, and Yab's
/// own saving (Thrift) following the same choice.
@MainActor
struct EnergySaverTests {
    @Test func offUntilChosen() {
        let held = Store.settings.object(forKey: EnergySaver.key)
        defer { Store.settings.set(held, forKey: EnergySaver.key) }
        Store.settings.removeObject(forKey: EnergySaver.key)
        #expect(EnergySaver.current == .off)
        #expect(ChromiumEnergySaver.state == 0, "Chromium is told 0, not its own default 1 (below 20%)")
        Store.settings.set("nonsense", forKey: EnergySaver.key)
        #expect(EnergySaver.current == .off)
    }

    @Test func chromiumsStates() {
        #expect(EnergySaver.allCases.map(\.chromiumState) == [0, 1, 2])
        #expect(EnergySaver.threshold == 20)
    }

    /// DesktopBatterySaverProvider::UpdateBatterySaverModeState.
    @Test func chromiumsRule() {
        for percent in [nil, 5, 19, 20, 80] as [Int?] {
            for onBattery in [false, true] {
                #expect(!EnergySaver.off.saves(onBattery: onBattery, percent: percent))
                #expect(EnergySaver.unplugged.saves(onBattery: onBattery, percent: percent) == onBattery)
            }
        }
        #expect(EnergySaver.low.saves(onBattery: true, percent: 19))
        #expect(!EnergySaver.low.saves(onBattery: true, percent: 20), "battery_percentage_ < 20, as Chromium counts")
        #expect(!EnergySaver.low.saves(onBattery: false, percent: 5), "plugged in never saves")
        #expect(!EnergySaver.low.saves(onBattery: true, percent: nil))
    }

    /// The bench's forced saving is Chrome's kEnabled, both engines at once;
    /// the setting off leaves Thrift off whatever macOS Low Power Mode says.
    @Test func thriftFollowsTheChoice() {
        let held = Store.settings.object(forKey: EnergySaver.key)
        defer { Thrift.forced = false; Store.settings.set(held, forKey: EnergySaver.key); Thrift.look() }
        Store.settings.removeObject(forKey: EnergySaver.key)
        Thrift.forced = false
        Thrift.look()
        #expect(!Thrift.on)
        Thrift.forced = true
        #expect(Thrift.on && ChromiumEnergySaver.state == 3)
        Thrift.forced = false
        #expect(!Thrift.on && ChromiumEnergySaver.state == 0)
        EnergySaver.current = .unplugged
        #expect(ChromiumEnergySaver.state == 2)
        #expect(Thrift.on == Power.now().onBattery)
    }

    @Test func agentCanChangeIt() throws {
        let held = Store.settings.object(forKey: EnergySaver.key)
        defer { Store.settings.set(held, forKey: EnergySaver.key); Thrift.look() }
        let setting = try #require(NativeSetting.all.first { $0.id == "energy-saver" })
        let prefs = Preferences()
        try setting.write(prefs, .string("low"))
        #expect(EnergySaver.current == .low && setting.read(prefs) == .string("low"))
        #expect(throws: NativeFailure.self) { try setting.write(prefs, .string("always")) }
        #expect(TaskWords.nativeRequest("turn on energy saver"))
        #expect(SettingsItem.all.contains { $0.id == "energy-saver" && $0.page == .tabs })
    }
}

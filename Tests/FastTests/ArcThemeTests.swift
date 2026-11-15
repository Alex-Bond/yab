import AppKit
import Testing
@testable import Fast

// Request #464: every space brought from Arc came with a stray black dot
// among its colors, and taking it away took all but one. The two themes
// here are two spaces' windowTheme read from a real Arc (farm, 2026-10-22,
// evals/arc-themes/dump.py): a two-color gradient in light, grain 0.1, and
// a dark one, grain 0.05, each with Arc's overlayColors (an alpha 0 black
// first) and its primary and semantic palettes beside.
@MainActor
struct ArcThemeTests {
    static func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.replacingOccurrences(of: "\n", with: "").utf8))
    }

    static let bright = json(#"""
{"background":{"single":{"_0":{"contentOverBackgroundAppearance":"light","isVibrant":true,"style":{"color":{"_0":{"blendedGradient":{"_0":{"baseColors
":[{"alpha":1,"blue":0.5843827128410339,"colorSpace":"extendedSRGB","green":0.9099058508872986,"red":0.20351433753967285},{"alpha":1,"blue":0.90400129
55665588,"colorSpace":"extendedSRGB","green":0.8972973823547363,"red":0.21980729699134827}],"modifiers":{"intensityFactor":0,"noiseFactor":0.1,"overla
y":"grain"},"overlayColors":[{"alpha":0,"blue":0,"colorSpace":"extendedSRGB","green":0,"red":0},{"alpha":1,"blue":0.38245466351509094,"colorSpace":"ex
tendedSRGB","green":0.9071203470230103,"red":0.4806128740310669}],"translucencyStyle":"light","wheel":{"analogous":{}}}}}}}}}},"primaryColorPalette":{
"midTone":{"alpha":1,"blue":0.33840322494506836,"colorSpace":"extendedSRGB","green":0.8467977643013,"red":-0.38497161865234375},"shaded":{"alpha":1,"b
lue":0.33840322494506836,"colorSpace":"extendedSRGB","green":0.8467977643013,"red":-0.38497161865234375},"shadedDark":{"alpha":1,"blue":0.162576973438
26294,"colorSpace":"extendedSRGB","green":0.40146076679229736,"red":-0.1562574803829193},"tintedLight":{"alpha":1,"blue":0.866992175579071,"colorSpace
":"extendedSRGB","green":0.971996009349823,"red":0.783880352973938}},"semanticColorPalette":{"appearanceBased":{"dark":{"background":{"alpha":1,"blue"
:0.04877309203147888,"colorSpace":"extendedSRGB","green":0.1204382300376892,"red":-0.046877244114875795},"backgroundExtra":{"alpha":1,"blue":0.0243865
4601573944,"colorSpace":"extendedSRGB","green":0.0602191150188446,"red":-0.023438622057437897},"cutoutColor":{"alpha":1,"blue":0.16257697343826294,"co
lorSpace":"extendedSRGB","green":0.40146076679229736,"red":-0.1562574803829193},"focus":{"alpha":0.8075,"blue":0.32591336965560913,"colorSpace":"exten
dedSRGB","green":0.5182037353515625,"red":0.0692664235830307},"foregroundPrimary":{"alpha":1,"blue":0.866992175579071,"colorSpace":"extendedSRGB","gre
en":0.971996009349823,"red":0.783880352973938},"foregroundSecondary":{"alpha":1,"blue":0.33840322494506836,"colorSpace":"extendedSRGB","green":0.84679
77643013,"red":-0.38497161865234375},"foregroundTertiary":{"alpha":1,"blue":0.33840322494506836,"colorSpace":"extendedSRGB","green":0.8467977643013,"r
ed":-0.38497161865234375},"hover":{"alpha":0.48,"blue":0.3893790543079376,"colorSpace":"extendedSRGB","green":0.5635651350021362,"red":0.1568956077098
8464},"maxContrastColor":{"alpha":1,"blue":0.866992175579071,"colorSpace":"extendedSRGB","green":0.971996009349823,"red":0.783880352973938},"minContra
stColor":{"alpha":1,"blue":0.16257697343826294,"colorSpace":"extendedSRGB","green":0.40146076679229736,"red":-0.1562574803829193},"subtitle":{"alpha":
1,"blue":0.4334960877895355,"colorSpace":"extendedSRGB","green":0.4859980046749115,"red":0.391940176486969},"title":{"alpha":1,"blue":0.87438654899597
17,"colorSpace":"extendedSRGB","green":0.9102191925048828,"red":0.8265613317489624}},"light":{"background":{"alpha":1,"blue":0.9162576794624329,"color
Space":"extendedSRGB","green":0.9401460886001587,"red":0.8843742609024048},"backgroundExtra":{"alpha":1,"blue":0.9916257858276367,"colorSpace":"extend
edSRGB","green":0.9940146207809448,"red":0.9884374141693115},"cutoutColor":{"alpha":1,"blue":0.866992175579071,"colorSpace":"extendedSRGB","green":0.9
71996009349823,"red":0.783880352973938},"focus":{"alpha":1,"blue":0.5812884569168091,"colorSpace":"extendedSRGB","green":0.7007303833961487,"red":0.42
187124490737915},"foregroundPrimary":{"alpha":1,"blue":0.33840322494506836,"colorSpace":"extendedSRGB","green":0.8467977643013,"red":-0.38497161865234
375},"foregroundSecondary":{"alpha":1,"blue":0.33840322494506836,"colorSpace":"extendedSRGB","green":0.8467977643013,"red":-0.38497161865234375},"fore
groundTertiary":{"alpha":1,"blue":0.866992175579071,"colorSpace":"extendedSRGB","green":0.971996009349823,"red":0.783880352973938},"hover":{"alpha":1,
"blue":0.8325153589248657,"colorSpace":"extendedSRGB","green":0.8802921772003174,"red":0.7687485218048096},"maxContrastColor":{"alpha":1,"blue":0.1625
7697343826294,"colorSpace":"extendedSRGB","green":0.40146076679229736,"red":-0.1562574803829193},"minContrastColor":{"alpha":1,"blue":0.86699217557907
1,"colorSpace":"extendedSRGB","green":0.971996009349823,"red":0.783880352973938},"subtitle":{"alpha":1,"blue":0.6650307774543762,"colorSpace":"extende
dSRGB","green":0.7605843544006348,"red":0.5374969840049744},"title":{"alpha":1,"blue":0.04877309203147888,"colorSpace":"extendedSRGB","green":0.120438
2300376892,"red":-0.046877244114875795}}}}}
"""#)

    static let dark = json(#"""
{"background":{"single":{"_0":{"contentOverBackgroundAppearance":"dark","isVibrant":true,"style":{"color":{"_0":{"blendedGradient":{"_0":{"baseColors"
:[{"alpha":1,"blue":0.09814844280481339,"colorSpace":"extendedSRGB","green":0.15601658821105957,"red":0.11565864831209183},{"alpha":1,"blue":0.1589145
064353943,"colorSpace":"extendedSRGB","green":0.10344456881284714,"red":0.11036748439073563}],"modifiers":{"intensityFactor":0.5453162560096154,"noise
Factor":0.05,"overlay":"grain"},"overlayColors":[{"alpha":0,"blue":0,"colorSpace":"extendedSRGB","green":0,"red":0},{"alpha":1,"blue":0.15226560831069
946,"colorSpace":"extendedSRGB","green":0.10098958760499954,"red":0.16416850686073303}],"translucencyStyle":"light","wheel":{"complimentary":{}}}}}}}}
}},"primaryColorPalette":{"midTone":{"alpha":1,"blue":0.41516226530075073,"colorSpace":"extendedSRGB","green":0.6266273856163025,"red":0.4790263175964
3555},"shaded":{"alpha":1,"blue":0.09814844280481339,"colorSpace":"extendedSRGB","green":0.15601658821105957,"red":0.11565864831209183},"shadedDark":{
"alpha":1,"blue":0.09814844280481339,"colorSpace":"extendedSRGB","green":0.15601658821105957,"red":0.11565864831209183},"tintedLight":{"alpha":1,"blue
":0.9127960801124573,"colorSpace":"extendedSRGB","green":0.9439697861671448,"red":0.9223776459693909}},"semanticColorPalette":{"appearanceBased":{"dar
k":{"background":{"alpha":1,"blue":0.029444532468914986,"colorSpace":"extendedSRGB","green":0.04680497199296951,"red":0.03469759598374367},"background
Extra":{"alpha":1,"blue":0.014722266234457493,"colorSpace":"extendedSRGB","green":0.023402485996484756,"red":0.017348797991871834},"cutoutColor":{"alp
ha":1,"blue":0.09814844280481339,"colorSpace":"extendedSRGB","green":0.15601658821105957,"red":0.11565864831209183},"focus":{"alpha":0.8075,"blue":0.2
7405139803886414,"colorSpace":"extendedSRGB","green":0.32063254714012146,"red":0.2881462872028351},"foregroundPrimary":{"alpha":1,"blue":0.91279608011
24573,"colorSpace":"extendedSRGB","green":0.9439697861671448,"red":0.9223776459693909},"foregroundSecondary":{"alpha":1,"blue":0.41516226530075073,"co
lorSpace":"extendedSRGB","green":0.6266273856163025,"red":0.47902631759643555},"foregroundTertiary":{"alpha":1,"blue":0.09814844280481339,"colorSpace"
:"extendedSRGB","green":0.15601658821105957,"red":0.11565864831209183},"hover":{"alpha":0.48,"blue":0.342399924993515,"colorSpace":"extendedSRGB","gre
en":0.38459542393684387,"red":0.35516777634620667},"maxContrastColor":{"alpha":1,"blue":0.9127960801124573,"colorSpace":"extendedSRGB","green":0.94396
97861671448,"red":0.9223776459693909},"minContrastColor":{"alpha":1,"blue":0.09814844280481339,"colorSpace":"extendedSRGB","green":0.15601658821105957
,"red":0.11565864831209183},"subtitle":{"alpha":1,"blue":0.456398069858551,"colorSpace":"extendedSRGB","green":0.4719849228858948,"red":0.461188852787
0178},"title":{"alpha":1,"blue":0.8647222518920898,"colorSpace":"extendedSRGB","green":0.87340247631073,"red":0.8673487901687622}},"light":{"backgroun
d":{"alpha":1,"blue":0.9098148345947266,"colorSpace":"extendedSRGB","green":0.9156017303466797,"red":0.9115658402442932},"backgroundExtra":{"alpha":1,
"blue":0.9909814596176147,"colorSpace":"extendedSRGB","green":0.991560161113739,"red":0.9911565780639648},"cutoutColor":{"alpha":1,"blue":0.9127960801
124573,"colorSpace":"extendedSRGB","green":0.9439697861671448,"red":0.9223776459693909},"focus":{"alpha":1,"blue":0.5490742325782776,"colorSpace":"ext
endedSRGB","green":0.5780082941055298,"red":0.5578293204307556},"foregroundPrimary":{"alpha":1,"blue":0.09814844280481339,"colorSpace":"extendedSRGB",
"green":0.15601658821105957,"red":0.11565864831209183},"foregroundSecondary":{"alpha":1,"blue":0.41516226530075073,"colorSpace":"extendedSRGB","green"
:0.6266273856163025,"red":0.47902631759643555},"foregroundTertiary":{"alpha":1,"blue":0.9127960801124573,"colorSpace":"extendedSRGB","green":0.9439697
861671448,"red":0.9223776459693909},"hover":{"alpha":1,"blue":0.8196296691894531,"colorSpace":"extendedSRGB","green":0.8312033414840698,"red":0.823131
7400932312},"maxContrastColor":{"alpha":1,"blue":0.09814844280481339,"colorSpace":"extendedSRGB","green":0.15601658821105957,"red":0.11565864831209183
},"minContrastColor":{"alpha":1,"blue":0.9127960801124573,"colorSpace":"extendedSRGB","green":0.9439697861671448,"red":0.9223776459693909},"subtitle":
{"alpha":1,"blue":0.639259397983551,"colorSpace":"extendedSRGB","green":0.6624066233634949,"red":0.6462634801864624},"title":{"alpha":1,"blue":0.02944
4532468914986,"colorSpace":"extendedSRGB","green":0.04680497199296951,"red":0.03469759598374367}}}}}
"""#)

    /// A windowTheme of Arc's shape: one color or a gradient of several.
    nonisolated static func theme(_ colors: [(Double, Double, Double)], overlay: String? = "grain", noise: Double? = nil) -> [String: Any] {
        func color(_ c: (Double, Double, Double), alpha: Double = 1) -> [String: Any] {
            ["red": c.0, "green": c.1, "blue": c.2, "alpha": alpha, "colorSpace": "extendedSRGB"]
        }
        var modifiers: [String: Any] = ["intensityFactor": 0.4]
        if let overlay { modifiers["overlay"] = overlay }
        if let noise { modifiers["noiseFactor"] = noise }
        let overlays = [color((0, 0, 0), alpha: 0), color((0.5, 0.5, 0.5))]
        let style: [String: Any] = colors.count == 1
            ? ["blendedSingleColor": ["_0": ["color": color(colors[0]), "modifiers": modifiers, "overlayColors": overlays]]]
            : ["blendedGradient": ["_0": ["baseColors": colors.map { color($0) }, "modifiers": modifiers, "overlayColors": overlays,
                                          "wheel": ["triad": [String: Any]()]]]]
        return ["background": ["single": ["_0": ["contentOverBackgroundAppearance": "light", "isVibrant": true,
                                                  "style": ["color": ["_0": style]]]]],
                "primaryColorPalette": ["midTone": color((0.1, 0.1, 0.1)), "shaded": color((0, 0, 0))],
                "semanticColorPalette": ["appearanceBased": ["light": ["foregroundPrimary": color((0, 0, 0))],
                                                              "dark": ["background": color((0.02, 0.02, 0.02))]]]]
    }

    @Test func aRealGradientComesAsItsTwoColorsAndGrain() {
        let look = ArcSidebar.theme(Self.bright)
        #expect(look.color == "34E895")
        #expect(look.colors == ["38E5E7"])
        #expect(look.grain == Grain.fromArc(0.1))
    }

    @Test func aRealDarkGradientComesAsItsTwoColorsAndGrain() {
        let look = ArcSidebar.theme(Self.dark)
        #expect(look.color == "1D2819")
        #expect(look.colors == ["1C1A29"])
        #expect(look.grain == Grain.fromArc(0.05))
    }

    @Test func noStrayBlackOnAnySpace() {
        for raw in [Self.bright, Self.dark, Self.theme([(0.9, 0.3, 0.5)]), Self.theme([(0.9, 0.3, 0.5), (0.2, 0.4, 0.9), (0.95, 0.75, 0.25)])] {
            let look = ArcSidebar.theme(raw)
            #expect(look.color != "000000")
            #expect(!look.colors.contains("000000"))
            #expect(!look.colors.contains("808080"))
        }
    }

    @Test func oneTwoAndThreeColorsInArcsOrder() {
        #expect(ArcSidebar.theme(Self.theme([(1, 0, 0)])).color == "FF0000")
        #expect(ArcSidebar.theme(Self.theme([(1, 0, 0)])).colors == [])
        let two = ArcSidebar.theme(Self.theme([(1, 0, 0), (0, 0, 1)]))
        #expect(two.color == "FF0000")
        #expect(two.colors == ["0000FF"])
        let three = ArcSidebar.theme(Self.theme([(0.9, 0.3, 0.5), (0.2, 0.4, 0.9), (0.95, 0.75, 0.25)]))
        #expect(three.color == "E64D80")
        #expect(three.colors == ["3366E6", "F2BF40"])
    }

    @Test func extendedSRGBPastTheEdgesIsClamped() {
        let look = ArcSidebar.theme(Self.theme([(-0.38, 0.85, 1.2)]))
        #expect(look.color == "00D9FF")
    }

    @Test func grainIsTheNoiseFactorOfAnyTexture() {
        #expect(ArcSidebar.theme(Self.theme([(1, 0, 0)], overlay: "grain", noise: 0.65)).grain == Grain.fromArc(0.65))
        #expect(ArcSidebar.theme(Self.theme([(1, 0, 0)], overlay: "tweed", noise: 0.3)).grain == Grain.fromArc(0.3))
        #expect(ArcSidebar.theme(Self.theme([(1, 0, 0)], overlay: "grain")).grain == Grain.standard)
        #expect(ArcSidebar.theme(Self.theme([(1, 0, 0)], overlay: nil, noise: 0.5)).grain == 0)
    }

    /// The space as Yab wears it: Arc's colors as they are, in its order,
    /// its own color rather than a preset near it.
    @Test func theImportedLookIsArcs() throws {
        let look = ArcSidebar.theme(Self.bright)
        let place = TabImport.Place(id: "Arc:1", name: "21", color: look.color, grain: look.grain, colors: look.colors,
                                    profile: "Default", shared: true, pinned: [], open: [])
        let paint = try #require(place.paint(Preferences()))
        #expect(paint.picked == .custom)
        #expect(paint.color == "34E895")
        #expect(paint.colors == ["38E5E7"])
        #expect(paint.grain == Grain.fromArc(0.1))
    }

    /// Taking dot 2 of 3 of a space brought from Arc leaves 1 and 3.
    @Test func removingTheMiddleOfThreeLeavesTheOtherTwo() throws {
        let look = ArcSidebar.theme(Self.theme([(0.9, 0.3, 0.5), (0.2, 0.4, 0.9), (0.95, 0.75, 0.25)]))
        let main = try #require(look.color.flatMap(NSColor.init(hex:)))
        let harmony = LookHarmony(primary: LookColor(main), colors: look.colors)
        let shown = harmony.colors(from: LookColor(main)).map(\.color.hex)
        let fewer = harmony.removing(0)
        let after = harmony.closingUp(after: fewer)
        #expect(after.colors(from: LookColor(main)).map(\.color.hex) == [shown[1]])
        #expect(after.links.count == 1)
    }

    /// Spaces brought in before: the black and what came past it go, the
    /// space's own colors stay; a list the editor made stays as it is.
    @Test func anEarlierImportIsRepaired() {
        #expect(ArcSidebar.repaired(["38E5E7", "000000", "7BE762", "00D856"]) == ["38E5E7"])
        #expect(ArcSidebar.repaired(["1C1A29", "000000", "2A1A27", "7AA06A"]) == ["1C1A29"])
        #expect(ArcSidebar.repaired(["000000", "7BE762", "00D856"]) == [])
        #expect(ArcSidebar.repaired(["000000", "FFFFFF"]) == ["000000", "FFFFFF"])
        #expect(ArcSidebar.repaired(["3366E6", "F2BF40"]) == ["3366E6", "F2BF40"])
    }

    @Test func anEarlierImportIsRepairedAsTheSpaceIsRead() throws {
        let saved = #"{"swatch":"custom","color":"34E895","grain":true,"grainAmount":0.1,"transparency":0,"colors":["38E5E7","000000","7BE762","00D856"]}"#
        let paint = try JSONDecoder().decode(SpacePaint.self, from: Data(saved.utf8))
        #expect(paint.colors == ["38E5E7"])
    }
}

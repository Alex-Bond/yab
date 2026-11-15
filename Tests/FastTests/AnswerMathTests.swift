import AppKit
import Foundation
import Testing
@testable import Fast

// Math and links in an answer (Math.swift, AnswerLinks.swift): where TeX
// is found and where a dollar stays a dollar, math set apart as a block,
// and every piece of TeX set as a picture of some size.
@MainActor
struct AnswerMathTests {
    private func found(_ text: String) -> [String] { MathTeX.spans(text).map(\.tex) }

    @Test func mathIsFoundInEachOfItsMarks() {
        #expect(found("so $x^2 + 1$ grows") == ["x^2 + 1"])
        #expect(found("where \\(a \\ne b\\) holds") == ["a \\ne b"])
        #expect(found("then $$\\int_0^1 f$$ and \\[E = mc^2\\]") == ["\\int_0^1 f", "E = mc^2"])
        #expect(MathTeX.spans("$$x$$").first?.display == true)
        #expect(MathTeX.spans("$x$").first?.display == false)
    }

    @Test func aDollarInProseStaysADollar() {
        #expect(found("It costs $5 and $10 a month.") == [])
        #expect(found("US$5 or $20, whichever") == [])
        #expect(found("$5-$10") == [])
        #expect(found("between $ 3 and 4 $") == [])
        #expect(found("a \\$5 fee and $x$") == ["x"])
        #expect(found("$5 now, then $y$ later") == ["y"])
        // Not across lines, not in code.
        #expect(found("$a\nb$") == [])
        #expect(found("run `echo $HOME $PATH` here") == [])
    }

    @Test func markdownLeavesMathAlone() {
        let marked = MathTeX.marked("**bold** and $a_1 * b_2 * c$")
        #expect(!marked.contains("$"))
        let rich = AgentAnswer.rich(marked)
        let pieces = MathTeX.pieces(String(rich.characters))
        #expect(pieces.contains { $0.math?.tex == "a_1 * b_2 * c" })
    }

    @Test func mathOnItsOwnLinesIsABlock() {
        #expect(ChatWords.blocks("Area:\n\n$$\\pi r^2$$\n\nDone.") == [.words("Area:"), .math("\\pi r^2"), .words("Done.")])
        #expect(ChatWords.blocks("$$\na + b\n= c\n$$") == [.math("a + b\n= c")])
        #expect(ChatWords.blocks("\\[\n\\frac{1}{2}\n\\]") == [.math("\\frac{1}{2}")])
        // Being written: not shown until it closes.
        #expect(ChatWords.blocks("Area:\n$$\n\\pi r", streaming: true) == [.words("Area:")])
        #expect(ChatWords.settled("so \\(x + ") == "so ")
        #expect(ChatWords.settled("so $$x") == "so ")
        // Never closed: shown as written.
        #expect(ChatWords.blocks("$$\nx") == [.words("$$\nx")])
    }

    @Test func everyPieceOfTeXIsSet() {
        let samples = [
            "x", "x^2", "x_i^2", "\\frac{a}{b}", "\\sqrt{x^2+y^2}", "\\sqrt[3]{8}", "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            "\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}", "\\left( \\frac{a}{b} \\right)^2", "\\mathbb{R}^n",
            "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}", "f(x) = \\begin{cases} 1 & x > 0 \\\\ 0 & \\text{otherwise} \\end{cases}",
            "\\begin{aligned} a &= b + c \\\\ &= d \\end{aligned}", "\\hat{x} + \\vec{v} + \\overline{AB}", "\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1",
            "\\binom{n}{k}", "\\alpha\\beta\\Gamma", "\\unknown{x}", "{", "}", "^", "\\frac{1}", "\\left(", "\\begin{matrix}",
        ]
        for tex in samples {
            for display in [false, true] {
                let picture = MathTeX.picture(tex, size: 13.5, display: display)
                #expect(picture.width > 1, "\(tex)")
                #expect(picture.image.size.height > 1, "\(tex)")
                #expect(picture.descent >= 0, "\(tex)")
            }
        }
        // A display fraction stands taller than its line form.
        #expect(MathTeX.picture("\\frac{a}{b}", size: 13.5, display: true).image.size.height
            > MathTeX.picture("\\frac{a}{b}", size: 13.5, display: false).image.size.height)
    }

    @Test func linksOnTheWebWearTheirSitesIcon() {
        #expect(AnswerLinks.host(URL(string: "https://www.apple.com/mac")!) == "www.apple.com")
        #expect(AnswerLinks.host(URL(string: "mailto:a@b.c")!) == nil)
        #expect(AnswerLinks.linked("see [Apple](https://apple.com)"))
        #expect(!AnswerLinks.linked("no links [here]"))
    }
}

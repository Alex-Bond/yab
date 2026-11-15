import Foundation
import Testing
@testable import Fast

@Suite("Original popup probe input") @MainActor
struct ChromiumPopupProbeInputTests {
    var request: [String: Any] {
        ["token": "original-popup", "extension": String(repeating: "a", count: 32),
         "context": 17, "window": 41, "x": 20.5, "y": 30.5, "contentWidth": 200, "contentHeight": 100]
    }
    @Test func exactOriginalLeaseAndPoint() throws {
        let input = try #require(ChromiumPopupProbeInput(request))
        #expect(input.matches(token: "original-popup", extensionID: String(repeating: "a", count: 32),
                              context: 17, window: 41, size: CGSize(width: 200, height: 100)))
    }
    @Test func booleanIsNeverANumericCoordinateOrIdentity() {
        for field in ["context", "window", "x", "y", "contentWidth", "contentHeight"] {
            var value = request; value[field] = true
            #expect(ChromiumPopupProbeInput(value) == nil)
        }
    }
    @Test func fractionalOrOverflowingNativeIdentitiesRefuseWithoutConversionTrap() {
        for field in ["context", "window"] {
            for number in [1.5, -1, 0, Double.greatestFiniteMagnitude, Double.infinity, Double.nan] {
                var value = request; value[field] = number
                #expect(ChromiumPopupProbeInput(value) == nil)
            }
        }
    }
    @Test func malformedOrMissingOriginalTokensAreNotAdmitted() {
        for token in ["", String(repeating: "a", count: 257)] {
            var value = request; value["token"] = token
            #expect(ChromiumPopupProbeInput(value) == nil)
        }
        var missing = request; missing.removeValue(forKey: "token")
        #expect(ChromiumPopupProbeInput(missing) == nil)
    }
    @Test func wrongExtensionAlphabetCannotSelectAnotherView() {
        for id in [String(repeating: "q", count: 32), String(repeating: "é", count: 16), "a"] {
            var value = request; value["extension"] = id
            #expect(ChromiumPopupProbeInput(value) == nil)
        }
    }
    @Test func missingNonfiniteOrUnavailableCapturedContentSizeRefuses() {
        for field in ["contentWidth", "contentHeight"] {
            for number in [0, -1, 32769, Double.infinity, Double.nan] {
                var value = request; value[field] = number
                #expect(ChromiumPopupProbeInput(value) == nil)
            }
            var missing = request; missing.removeValue(forKey: field)
            #expect(ChromiumPopupProbeInput(missing) == nil)
        }
    }
    @Test func nonfiniteOrNegativePointsRefuse() {
        for field in ["x", "y"] {
            for number in [-0.1, 32768, Double.infinity, Double.nan] {
                var value = request; value[field] = number
                #expect(ChromiumPopupProbeInput(value) == nil)
            }
        }
    }
    @Test func replacementTokenContextWindowOrExtensionCannotReuseAValidPoint() throws {
        let input = try #require(ChromiumPopupProbeInput(request))
        let id = String(repeating: "a", count: 32), size = CGSize(width: 200, height: 100)
        #expect(!input.matches(token: "replacement", extensionID: id, context: 17, window: 41, size: size))
        #expect(!input.matches(token: "original-popup", extensionID: id, context: 18, window: 41, size: size))
        #expect(!input.matches(token: "original-popup", extensionID: id, context: 17, window: 42, size: size))
        #expect(!input.matches(token: "original-popup", extensionID: String(repeating: "b", count: 32), context: 17, window: 41, size: size))
    }
    @Test func resizedOrUnavailableOriginalBoundsVetoAnOldPoint() throws {
        let input = try #require(ChromiumPopupProbeInput(request))
        for size in [CGSize(width: 400, height: 200), CGSize(width: 200.001, height: 100), CGSize.zero, CGSize(width: 20.5, height: 100), CGSize(width: 200, height: 30.5), CGSize(width: CGFloat.infinity, height: 100)] {
            #expect(!input.matches(token: "original-popup", extensionID: String(repeating: "a", count: 32), context: 17, window: 41, size: size))
        }
    }
}

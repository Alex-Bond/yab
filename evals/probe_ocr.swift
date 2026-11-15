// The words in a picture, one line each, as Vision reads them: what a
// person would read on screen, for evals that check what is said rather
// than what the app holds (evals/probe_ocr.py).
//   probe_ocr PICTURE [X Y W H]   the rectangle in the picture's pixels, from its top left
// With PROBE_OCR_BOXES=1 in its environment each line is followed, after a
// tab, by where it stands: x, y, width and height in the whole picture's
// pixels from its top left.
import AppKit
import Vision

let args = CommandLine.arguments
guard args.count >= 2, let image = NSImage(contentsOfFile: args[1]),
      var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("probe_ocr: no picture\n".data(using: .utf8)!)
    exit(1)
}
var origin = CGPoint.zero
if args.count >= 6, let x = Double(args[2]), let y = Double(args[3]), let w = Double(args[4]), let h = Double(args[5]),
   let part = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) {
    cg = part
    origin = CGPoint(x: x, y: y)
}
let boxes = ProcessInfo.processInfo.environment["PROBE_OCR_BOXES"] == "1"
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cg).perform([request])
let width = CGFloat(cg.width), height = CGFloat(cg.height)
for observation in request.results ?? [] {
    guard let best = observation.topCandidates(1).first else { continue }
    if boxes {
        // Vision's box is normalized, from the bottom left.
        let box = observation.boundingBox
        let x = origin.x + box.minX * width, y = origin.y + (1 - box.maxY) * height
        print("\(best.string)\t\(Int(x))\t\(Int(y))\t\(Int(box.width * width))\t\(Int(box.height * height))")
    } else {
        print(best.string)
    }
}

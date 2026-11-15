// What a PDF holds, as JSON, for evals/save-page/check.py: its pages, the
// first page's size in points, its outline's labels and its words.
//   xcrun swift evals/save-page/pdfinfo.swift FILE.pdf
import Foundation
import PDFKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let document = PDFDocument(url: url) else {
    print("{\"error\": \"not a PDF\"}")
    exit(0)
}
var labels: [String] = []
if let root = document.outlineRoot {
    for index in 0..<root.numberOfChildren { labels.append(root.child(at: index)?.label ?? "") }
}
let box = document.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
let info: [String: Any] = ["pages": document.pageCount, "width": Int(box.width), "height": Int(box.height),
                           "outline": labels, "text": document.string ?? ""]
let data = try JSONSerialization.data(withJSONObject: info)
print(String(decoding: data, as: UTF8.self))

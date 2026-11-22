// ocr.swift — reads the text in images with Apple's Vision text recognizer
// (the same kind of OCR the App Store applies to screenshots).
//
//   swift ocr.swift --languages en-US,de-DE --crop 0,0,1,0.3 a.png b.png …
//   swift ocr.swift --supported
//
// --crop x,y,w,h is a fraction of the image (top-left origin) to read; default whole.
// Prints one JSON object per line: {"file": …, "text": "line one\nline two"}.
import Foundation
import Vision
import ImageIO
import CoreGraphics

var languages: [String] = ["en-US"]
var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
var files: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--languages": languages = args.removeFirst().split(separator: ",").map(String.init)
    case "--crop":
        let v = args.removeFirst().split(separator: ",").compactMap { Double($0) }
        crop = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    case "--supported":
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        print((try? request.supportedRecognitionLanguages()) ?? [])
        exit(0)
    default: files.append(a)
    }
}

for file in files {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
          var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("{\"file\": \(String(reflecting: file)), \"error\": \"unreadable\"}")
        continue
    }
    let w = CGFloat(image.width), h = CGFloat(image.height)
    if let cut = image.cropping(to: CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral) {
        image = cut
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = languages
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    // Top to bottom (Vision's origin is bottom-left).
    let lines = (request.results ?? [])
        .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        .compactMap { $0.topCandidates(1).first?.string }
    let payload = try! JSONSerialization.data(withJSONObject: ["file": file, "text": lines.joined(separator: "\n")])
    print(String(decoding: payload, as: UTF8.self))
}

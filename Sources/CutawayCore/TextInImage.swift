import AppKit
import Vision

/// Reading what is in a capture: the words, and any QR or barcode.
///
/// On-device Vision, so nothing leaves the Mac and it needs no permission.
public enum TextInImage {

    /// Lines of text, top to bottom, as they read on screen.
    public static func read(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { c in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    Log.line("ERROR: text recognition failed, \(error.localizedDescription)")
                    c.resume(returning: [])
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    // Vision returns bottom-up normalised boxes; reading order is top down
                    .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                    .compactMap { $0.topCandidates(1).first?.string }
                c.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            perform([request], on: image) { c.resume(returning: []) }
        }
    }

    /// The payload of any QR or barcode in the picture.
    public static func codes(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { c in
            let request = VNDetectBarcodesRequest { request, _ in
                let found = (request.results as? [VNBarcodeObservation] ?? [])
                    .compactMap { $0.payloadStringValue }
                c.resume(returning: found)
            }
            perform([request], on: image) { c.resume(returning: []) }
        }
    }

    private static func perform(_ requests: [VNRequest], on image: CGImage,
                                onFailure: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
            } catch {
                Log.line("ERROR: could not read the image, \(error.localizedDescription)")
                onFailure()
            }
        }
    }

    /// Text first, then any code, joined for the clipboard.
    @MainActor
    public static func copyEverything(from image: CGImage) async -> String {
        var parts = await read(image)
        let found = await codes(image)
        parts.append(contentsOf: found)
        let text = parts.joined(separator: "\n")
        guard !text.isEmpty else {
            Log.line("no text found in this capture")
            return ""
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.line("copied \(parts.count) line(s) of text from the capture")
        return text
    }
}

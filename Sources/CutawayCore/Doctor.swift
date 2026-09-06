import Foundation
import AVFoundation
import ScreenCaptureKit
import AppKit
import Metal

/// Checks everything Cutaway needs and says exactly what to do about whatever
/// is missing.
///
/// Permissions on macOS fail quietly and in confusing ways: a denied grant
/// looks like an empty display list, and a grant given to the wrong process
/// looks like a denial. One command that reports the real state saves more time
/// than any amount of guessing.
public enum Doctor {

    public struct Check {
        public let name: String
        public let ok: Bool
        public let detail: String
        /// What to do when it is not ok.
        public let fix: String?
    }

    public static func run() async -> [Check] {
        var checks: [Check] = []

        // Screen recording: the only way to know is to ask for content.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            let displays = content.displays.count
            checks.append(Check(
                name: "Screen recording",
                ok: displays > 0,
                detail: displays > 0 ? "\(displays) display(s), \(content.windows.count) windows"
                                     : "granted but no displays reported",
                fix: displays > 0 ? nil
                    : "System Settings > Privacy & Security > Screen & System Audio Recording"))
        } catch {
            checks.append(Check(
                name: "Screen recording",
                ok: false,
                detail: "denied",
                fix: """
                System Settings > Privacy & Security > Screen & System Audio Recording,
                enable Cutaway, then relaunch. If it is already enabled, toggle it off
                and on: macOS pins the grant to the binary, and a rebuild invalidates it.
                """))
        }

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        checks.append(Check(
            name: "Microphone",
            ok: mic == .authorized,
            detail: describe(mic),
            fix: mic == .authorized ? nil
                : "Record once and allow the prompt, or System Settings > Privacy & Security > Microphone"))

        let cam = AVCaptureDevice.authorizationStatus(for: .video)
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        checks.append(Check(
            name: "Camera",
            ok: cam == .authorized && !cameras.isEmpty,
            detail: cameras.isEmpty ? "no camera found"
                                    : "\(describe(cam)), \(cameras.count) device(s)",
            fix: cam == .authorized ? nil
                : "Record with the webcam once and allow the prompt"))

        let keys = EventRecorder.canCaptureKeys
        checks.append(Check(
            name: "Input monitoring",
            ok: keys,
            detail: keys ? "granted, keycast available" : "not granted, keycast will be skipped",
            fix: keys ? nil
                : "System Settings > Privacy & Security > Input Monitoring, enable Cutaway, then relaunch"))

        let speech = await Transcriber.requestAccess()
        checks.append(Check(
            name: "Speech recognition",
            ok: speech,
            detail: speech ? "on-device transcription available" : "not granted",
            fix: speech ? nil : "Record with a microphone once and allow the prompt"))

        let voices = VoiceoverRenderer.availableVoices()
        let good = voices.filter { $0.quality != "default" }
        checks.append(Check(
            name: "Speech voices",
            ok: !good.isEmpty,
            detail: "\(voices.count) english, \(good.count) enhanced or premium",
            fix: good.isEmpty ? """
                Only default-quality voices are installed, which sound robotic.
                System Settings > Accessibility > Spoken Content > System Voice >
                Manage Voices, then download a Premium voice.
                """ : nil))

        let ffmpeg = GIFEncoder.locateFFmpeg()
        checks.append(Check(
            name: "ffmpeg",
            ok: ffmpeg != nil,
            detail: ffmpeg?.path ?? "not found",
            fix: ffmpeg == nil ? "Only needed for GIF export: brew install ffmpeg" : nil))

        let metal = MTLCreateSystemDefaultDevice()
        checks.append(Check(
            name: "Metal",
            ok: metal != nil,
            detail: metal?.name ?? "no GPU",
            fix: nil))

        return checks
    }

    private static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
}

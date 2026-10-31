// Optional integration test: needs a locally downloaded Apple aerial.
// Uses the production VideoSession with a short, temporary local extract.
import AppKit
import AVFoundation

@main enum PlaybackTest {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
            let clips = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let source = clips.first(where: { $0.pathExtension == "mov" }) else {
                print("SKIP: no local aerial available"); exit(0)
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-loop-test-\(UUID().uuidString).mov")
            let asset = AVURLAsset(url: source)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { exit(1) }
            export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
            do { try await export.export(to: temp, as: .mov) }
            catch { print("FAIL: extract: \(error)"); exit(1) }
            let session = VideoSession(id: "loop-test", url: temp)
            var completions = 0
            session.onLoop = { completions += 1 }
            session.setPlaying(true)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard completions > 0, session.player.error == nil, session.player.rate == 1 else {
                print("FAIL: loop callbacks=\(completions), rate=\(session.player.rate), error=\(String(describing: session.player.error))"); exit(1)
            }
            session.setPlaying(false)
            // KVO callbacks already dispatched by the last loop can still be
            // in flight when pause returns. Drain them before measuring pause.
            try? await Task.sleep(nanoseconds: 100_000_000)
            let count = completions
            let time = session.player.currentTime().seconds
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard completions == count, session.player.rate == 0, abs(session.player.currentTime().seconds-time) < 0.05 else { print("FAIL: paused loop advanced"); exit(1) }
            try? FileManager.default.removeItem(at: temp)
            print("PASS: production loop callback fired \(count) times; 1× playback and pause verified")
            exit(0)
        }
        app.run()
    }
}

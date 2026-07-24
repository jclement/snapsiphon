import AVFoundation

/// "Pew pew mode": tiny synthesized tones for every pipeline event — a
/// falling chirp when a file exports, a zzt while it encrypts, a laser pew
/// when it uploads, a happy ding when it lands. Eight parallel lanes become a
/// tiny arcade. Off by default; respects the silent switch (.ambient) and
/// mixes politely with music.
///
/// No audio assets: every buffer is rendered from math at first use, so the
/// "every byte is auditable" story survives the fun.
@MainActor
final class PewPew {
    static let shared = PewPew()

    enum Event { case export, encrypt, upload, done, dedup, fail, journal, checkpoint }

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? start() : stop()
        }
    }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [Event: AVAudioPCMBuffer] = [:]
    private var next = 0
    private var running = false
    private let sampleRate = 44_100.0

    private init() {}

    func play(_ event: Event) {
        guard enabled, running, let buffer = buffers[event], !players.isEmpty else { return }
        let player = players[next % players.count]   // round-robin so tones overlap
        next += 1
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    // MARK: Engine lifecycle

    private func start() {
        guard !running else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if buffers.isEmpty { renderAll() }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        if players.isEmpty {
            for _ in 0..<10 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
                players.append(p)
            }
        }
        engine.mainMixerNode.outputVolume = 0.5
        try? engine.start()
        running = engine.isRunning
    }

    private func stop() {
        guard running else { return }
        players.forEach { $0.stop() }
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Synthesis

    private func renderAll() {
        // iCloud pull: gentle falling chirp.
        buffers[.export] = render(duration: 0.09, volume: 0.35) { p in 760 - 340 * p }
        // Encrypting: bitcrunchy two-tone zzt.
        buffers[.encrypt] = render(duration: 0.07, volume: 0.22, square: true) { p in p < 0.5 ? 620 : 840 }
        // Upload: the eponymous laser pew (fast falling square).
        buffers[.upload] = render(duration: 0.12, volume: 0.28, square: true, decayPower: 2.2) { p in 1400 - 1150 * p }
        // Landed: happy ding (E6).
        buffers[.done] = render(duration: 0.18, volume: 0.4, decayPower: 2.5) { _ in 1318.5 }
        // Dedup skip: tiny pop.
        buffers[.dedup] = render(duration: 0.045, volume: 0.3) { _ in 700 }
        // Failure: low sad buzz.
        buffers[.fail] = render(duration: 0.22, volume: 0.35, square: true, decayPower: 1.5) { _ in 130 }
        // Journal commit: quick ascending arpeggio (C5-E5-G5).
        buffers[.journal] = render(duration: 0.16, volume: 0.35) { p in p < 0.34 ? 523.3 : (p < 0.67 ? 659.3 : 784.0) }
        // Checkpoint: triumphant octave sweep.
        buffers[.checkpoint] = render(duration: 0.32, volume: 0.4, decayPower: 1.8) { p in 523.3 * pow(2, p) }
    }

    private func render(duration: Double, volume: Float,
                        square: Bool = false, decayPower: Double = 3,
                        freq: (Double) -> Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        var phase = 0.0
        for i in 0..<Int(frames) {
            let p = Double(i) / Double(frames)          // 0…1 through the tone
            phase += 2 * .pi * freq(p) / sampleRate     // integrate so sweeps are smooth
            var s = sin(phase)
            if square { s = s > 0 ? 0.6 : -0.6 }        // squares are loud; tame them
            let attack = min(1, p * 40)                  // declick
            data[i] = Float(s * attack * pow(1 - p, decayPower)) * volume
        }
        return buffer
    }
}

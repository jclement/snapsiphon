import Foundation

/// A true mid-stream upload throttle. We hand `URLSession` the *input* half of a
/// bound stream pair as the request body, and feed the *output* half from the
/// encrypted file at a rate the token bucket allows. Because `URLSession` can
/// only send as fast as we produce, this caps actual on-the-wire throughput —
/// not just the per-file average.
///
/// The producer runs on its own thread with a run loop so `Thread.sleep` (the
/// throttle) blocks nothing else.
final class ThrottledBodyStream: NSObject, StreamDelegate {
    /// Hand this to `URLRequest.httpBodyStream`.
    let bodyStream: InputStream

    private let output: OutputStream
    private let fileHandle: FileHandle
    private let limiter: SyncTokenBucket
    private let blockSize = 32 * 1024
    private var pending = Data()
    private var reachedEOF = false
    private var finished = false
    private var cancelled = false
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    init(fileURL: URL, bytesPerSecond: Double) throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64 * 1024, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw CocoaError(.fileReadUnknown) }
        self.bodyStream = input
        self.output = output
        self.fileHandle = try FileHandle(forReadingFrom: fileURL)
        self.limiter = SyncTokenBucket(bytesPerSecond: bytesPerSecond)
        super.init()
    }

    /// Begin producing. Call once, before/while the upload task runs.
    func start() {
        let thread = Thread { [self] in
            if cancelled { finish(); return }   // cancelled before we even started
            runLoop = CFRunLoopGetCurrent()
            output.delegate = self
            output.schedule(in: .current, forMode: .default)
            output.open()
            RunLoop.current.run()
        }
        thread.name = "ca.straybits.snapsiphon.throttle"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Tear down the producer once the upload task has finished. Without this,
    /// a completed upload whose output stream never fires a terminal event
    /// leaves the producer thread parked in its run loop forever — one leaked
    /// thread (plus stream buffers and an open file handle) per throttled
    /// upload. Idempotent; safe to call from any thread.
    func cancel() {
        cancelled = true
        guard let runLoop else { return }   // pre-start: the thread checks the flag
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in finish() }
        CFRunLoopWakeUp(runLoop)
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream === output else { return }
        switch eventCode {
        case .hasSpaceAvailable:
            pump()
        case .errorOccurred, .endEncountered:
            finish()
        default:
            break
        }
    }

    private func pump() {
        while output.hasSpaceAvailable {
            if pending.isEmpty {
                if reachedEOF { finish(); return }
                let chunk = fileHandle.readData(ofLength: blockSize)
                if chunk.isEmpty {
                    reachedEOF = true
                    finish()
                    return
                }
                // Throttle *before* feeding this block onto the wire.
                limiter.consume(chunk.count)
                pending = chunk
            }
            let written = pending.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base, maxLength: pending.count)
            }
            if written <= 0 { return }         // no space / error — wait for next event
            pending.removeFirst(written)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        output.close()
        output.remove(from: .current, forMode: .default)
        try? fileHandle.close()
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

/// A single-threaded pacing scheduler. Only ever touched from the producer
/// thread, so it can block that thread with `Thread.sleep` to enforce the rate.
///
/// Uses a virtual clock: each block of `n` bytes "costs" `n / rate` seconds, and
/// we advance a `nextSendTime` cursor by that cost, sleeping until the cursor is
/// reached before releasing the block. This holds the true average at the cap
/// (unlike a naive allowance bucket, which double-credits time spent asleep and
/// ends up running at roughly twice the limit). After an idle gap the cursor
/// snaps to now, so pauses don't bank up an unbounded burst.
final class SyncTokenBucket {
    private let bytesPerSecond: Double
    private var nextSendTime: Date

    init(bytesPerSecond: Double) {
        self.bytesPerSecond = bytesPerSecond
        self.nextSendTime = Date()
    }

    func consume(_ bytes: Int) {
        guard bytesPerSecond > 0 else { return }
        let now = Date()
        if nextSendTime < now { nextSendTime = now }        // don't bank idle time
        let releaseAt = nextSendTime
        nextSendTime = nextSendTime.addingTimeInterval(Double(bytes) / bytesPerSecond)
        let wait = releaseAt.timeIntervalSince(now)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }
}

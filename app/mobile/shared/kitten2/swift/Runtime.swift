import Foundation
import Kitten2Runtime

public struct Kitten2TokenBatch: Sendable {
    public let ids: [Int32]
    public let finished: Bool
}
public struct Kitten2RuntimeError: LocalizedError {
    public let message: String
    public init(message: String) { self.message=message }
    public var errorDescription: String? { message }
}
private final class TokenReceiver {
    let continuation: AsyncThrowingStream<Kitten2TokenBatch, Error>.Continuation
    init(_ continuation: AsyncThrowingStream<Kitten2TokenBatch, Error>.Continuation) { self.continuation = continuation }
}

/// One bounded generation at a time; the native mutex also protects foreign callers.
public final class Kitten2LanguageModel: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    public init(model: URL, conditioning: URL, useGPU: Bool? = nil) throws {
        var error: UnsafeMutablePointer<CChar>?
        let gpu: Int32 = useGPU == false ? 0 : 1
        let value = kitten2_create(model.path, conditioning.path, gpu, 3, &error)
        defer { kitten2_free(error) }
        guard let value else { throw Kitten2RuntimeError(message: error.map { String(cString: $0) } ?? "Kitten TTS 2 could not load.") }
        handle = value
    }
    deinit { kitten2_destroy(handle) }
    /// Foreground GPU use is independent of a background-task grant. The native
    /// gate drains GPU work and migrates context to CPU before deactivation ends.
    public static func setGPUAllowed(_ allowed: Bool) { kitten2_set_gpu_allowed(allowed ? 1 : 0) }
    public func cancel() { kitten2_cancel(handle) }
    public func conditioning(voice: String) throws -> Data {
        var error:UnsafeMutablePointer<CChar>?
        let value=kitten2_voice_conditioning(handle,voice,&error)
        defer { kitten2_free(error); kitten2_free(value) }
        guard let value else { throw Kitten2RuntimeError(message:error.map { String(cString:$0) } ?? "The voice could not be loaded.") }
        return Data(String(cString:value).utf8)
    }
    public func tokenCount(_ text: String) throws -> Int {
        let count=kitten2_token_count(handle,text)
        guard count>=0 else { throw Kitten2RuntimeError(message:"The passage could not be tokenized.") }
        return Int(count)
    }
    public func tokens(text: String, voice: String, expressive: Bool, hasExpression: Bool,
                       seed: UInt32 = .random(in: 0...UInt32.max)) -> AsyncThrowingStream<Kitten2TokenBatch, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let producer = Task.detached(priority: .userInitiated) { [self] in
                do {
                    try Task.checkCancellation()
                    let receiver = TokenReceiver(continuation)
                    let pointer = Unmanaged.passRetained(receiver).toOpaque()
                    defer { Unmanaged<TokenReceiver>.fromOpaque(pointer).release() }
                    var error: UnsafeMutablePointer<CChar>?
                    let result = kitten2_generate(handle, text, voice, (expressive ? 1 : 0) | (hasExpression ? 2 : 0), seed, 1000, { pointer, ids, count, final in
                        guard let pointer, let ids else { return 0 }
                        let receiver = Unmanaged<TokenReceiver>.fromOpaque(pointer).takeUnretainedValue()
                        let value = Kitten2TokenBatch(ids: Array(UnsafeBufferPointer(start: ids, count: count)), finished: final != 0)
                        if case .terminated = receiver.continuation.yield(value) { return 0 }
                        return 1
                    }, pointer, &error)
                    defer { kitten2_free(error) }
                    if result < 0 { throw CancellationError() }
                    guard result == 1 else { throw Kitten2RuntimeError(message: error.map { String(cString: $0) } ?? "The voice could not finish this passage.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { [self] reason in
                if case .cancelled = reason { producer.cancel(); cancel() }
            }
        }
    }
}

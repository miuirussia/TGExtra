import Foundation

public enum NoError {}
// Match the host: a class-bound existential returns object + witness in registers.
public protocol Disposable: AnyObject { func dispose() }

public enum DisposableProbe {
    private static let lock = NSLock()
    private static var count = 0
    public static var liveTokens: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    fileprivate static func track(_ delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        count += delta
    }
}

private final class Token: Disposable {
    init() { DisposableProbe.track(1) }
    deinit { DisposableProbe.track(-1) }
    func dispose() { preconditionFailure("Cleanup must not cancel the transaction") }
}

public final class Signal<T, E> {
    private let run: (@escaping (T) -> Void, @escaping () -> Void) -> Void
    public init(_ run: @escaping (@escaping (T) -> Void, @escaping () -> Void) -> Void) { self.run = run }
    public func start(next: ((T) -> Void)? = nil, error: ((E) -> Void)? = nil, completed: (() -> Void)? = nil) -> Disposable {
        run({ next?($0) }, { completed?() })
        return Token()
    }
}

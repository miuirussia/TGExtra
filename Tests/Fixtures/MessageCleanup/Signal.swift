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
    let cancellable: Bool
    let cancellation: (() -> Void)?
    init(cancellable: Bool = false, cancellation: (() -> Void)? = nil) {
        self.cancellable = cancellable
        self.cancellation = cancellation
        DisposableProbe.track(1)
    }
    deinit { DisposableProbe.track(-1) }
    func dispose() {
        precondition(cancellable, "Cleanup must not cancel the transaction")
        cancellation?()
    }
}

public final class MetaDisposable {
    private var value: Disposable?
    public init() {}
    public func set(_ value: Disposable?) { self.value = value }
    public func dispose() { value?.dispose(); value = nil }
}

public final class Signal<T, E> {
    private let run: (@escaping (T) -> Void, @escaping () -> Void) -> Void
    private let runWithError: ((@escaping (T) -> Void, @escaping (E) -> Void, @escaping () -> Void) -> (() -> Void))?
    public init(_ run: @escaping (@escaping (T) -> Void, @escaping () -> Void) -> Void) {
        self.run = run
        runWithError = nil
    }
    public init(cancellable run: @escaping (@escaping (T) -> Void, @escaping (E) -> Void, @escaping () -> Void) -> (() -> Void)) {
        self.run = { _, _ in }
        runWithError = run
    }
    public func start(next: ((T) -> Void)? = nil, error: ((E) -> Void)? = nil, completed: (() -> Void)? = nil) -> Disposable {
        if let runWithError = runWithError {
            let cancellation = runWithError({ next?($0) }, { error?($0) }, { completed?() })
            return Token(cancellable: true, cancellation: cancellation)
        } else {
            run({ next?($0) }, { completed?() })
        }
        return Token()
    }
}

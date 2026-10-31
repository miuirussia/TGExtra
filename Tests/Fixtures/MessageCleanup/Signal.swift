import Foundation

public enum NoError {}
public protocol Disposable { func dispose() }
private final class Token: Disposable { func dispose() {} }

public final class Signal<T, E> {
    private let run: (@escaping (T) -> Void, @escaping () -> Void) -> Void
    public init(_ run: @escaping (@escaping (T) -> Void, @escaping () -> Void) -> Void) { self.run = run }
    public func start(next: ((T) -> Void)? = nil, error: ((E) -> Void)? = nil, completed: (() -> Void)? = nil) -> Disposable {
        run({ next?($0) }, { completed?() })
        return Token()
    }
}

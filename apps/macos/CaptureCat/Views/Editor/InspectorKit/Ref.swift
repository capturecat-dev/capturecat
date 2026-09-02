/// A get/set accessor pair — the AppKit replacement for SwiftUI's `Binding`.
///
/// The inspector panes were written against `Binding` while the column was
/// still reached through an `NSViewRepresentable`. `Ref` keeps the same
/// `wrappedValue` spelling (so `ref.wrappedValue?.field = x` still reads and
/// writes through) without dragging SwiftUI in.
struct Ref<Value> {
    private let getter: () -> Value
    private let setter: (Value) -> Void

    init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        getter = get
        setter = set
    }

    /// Reading calls `get`; writing calls `set`. `nonmutating` so a mutation
    /// through an optional chain (`wrappedValue?.zoomLevel = v`) resolves as
    /// get-modify-set rather than requiring a `var` binding.
    var wrappedValue: Value {
        get { getter() }
        nonmutating set { setter(newValue) }
    }

    /// A `Ref` that reads and writes nothing — for panes built without a
    /// selection context.
    static func constant(_ value: Value) -> Ref<Value> {
        Ref(get: { value }, set: { _ in })
    }
}

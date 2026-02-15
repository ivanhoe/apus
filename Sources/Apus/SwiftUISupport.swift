#if canImport(SwiftUI)
import SwiftUI
import Combine

// MARK: - @Inspectable Property Wrapper

/// Property wrapper that automatically registers an `ObservableObject` with Apus
/// for runtime inspection. When the object changes, the registration is updated.
///
/// ```swift
/// struct ContentView: View {
///     @Inspectable("profileVM") var viewModel = ProfileViewModel()
///
///     var body: some View {
///         Text(viewModel.name)
///     }
/// }
/// ```
///
/// This is equivalent to manually calling `Apus.shared.register(viewModel, id: "profileVM")`
/// but handles registration, updates, and cleanup automatically.
@propertyWrapper
public struct Inspectable<Value: ObservableObject>: DynamicProperty {
    @StateObject private var wrapper: InspectableWrapper<Value>

    public var wrappedValue: Value { wrapper.value }

    public var projectedValue: ObservedObject<Value>.Wrapper {
        ObservedObject(wrappedValue: wrapper.value).projectedValue
    }

    public init(wrappedValue: @autoclosure @escaping () -> Value, _ id: String) {
        _wrapper = StateObject(wrappedValue: InspectableWrapper(factory: wrappedValue, id: id))
    }
}

private final class InspectableWrapper<Value: ObservableObject>: ObservableObject {
    let value: Value
    let id: String
    private var cancellable: AnyCancellable?

    init(factory: () -> Value, id: String) {
        self.value = factory()
        self.id = id

        // Register with Apus
        Apus.shared.register(value, id: id)

        // Re-register on every change so Mirror reflects latest state
        cancellable = self.value.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Apus.shared.register(self.value, id: self.id)
            }
    }

    deinit {
        Apus.shared.unregister(id: id)
    }
}

// MARK: - View Modifier

extension View {
    /// Register an object for inspection when this view appears.
    /// The object is automatically unregistered when the view disappears.
    ///
    /// ```swift
    /// struct ProfileView: View {
    ///     @StateObject var viewModel = ProfileViewModel()
    ///
    ///     var body: some View {
    ///         Text(viewModel.name)
    ///             .apusInspectable(viewModel, id: "profileVM")
    ///     }
    /// }
    /// ```
    public func apusInspectable(_ object: Any, id: String) -> some View {
        self.modifier(ApusInspectableModifier(object: object, id: id))
    }

    /// Register a value for inspection using a provider closure.
    /// Useful for value types that change over time.
    ///
    /// ```swift
    /// struct CartView: View {
    ///     @State var items: [Item] = []
    ///
    ///     var body: some View {
    ///         List(items) { ... }
    ///             .apusInspectable(id: "cartItems") { items }
    ///     }
    /// }
    /// ```
    public func apusInspectable(id: String, provider: @escaping () -> Any?) -> some View {
        self.modifier(ApusProviderModifier(id: id, provider: provider))
    }
}

private struct ApusInspectableModifier: ViewModifier {
    let object: Any
    let id: String

    func body(content: Content) -> some View {
        content
            .onAppear { Apus.shared.register(object, id: id) }
            .onDisappear { Apus.shared.unregister(id: id) }
    }
}

private struct ApusProviderModifier: ViewModifier {
    let id: String
    let provider: () -> Any?

    func body(content: Content) -> some View {
        content
            .onAppear { Apus.shared.register(id: id, provider: provider) }
            .onDisappear { Apus.shared.unregister(id: id) }
    }
}

// MARK: - Hot Reload / Injection Support

#if DEBUG

/// Observable object that listens for injection bundle notifications.
/// When a dylib is loaded via HotReloadTool, this triggers SwiftUI to re-evaluate the view body.
private final class InjectionObserver: ObservableObject {
    @Published var injectionCount = 0

    private var cancellable: AnyCancellable?

    init() {
        cancellable = NotificationCenter.default
            .publisher(for: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"))
            .sink { [weak self] _ in
                self?.injectionCount += 1
            }
    }
}

/// Property wrapper that forces a SwiftUI view to re-render when a hot-reloaded dylib is injected.
///
/// ```swift
/// struct ContentView: View {
///     #if DEBUG
///     @ObserveInjection var forceReload
///     #endif
///
///     var body: some View {
///         Text("Hello")
///     }
/// }
/// ```
@propertyWrapper
public struct ObserveInjection: DynamicProperty {
    @StateObject private var observer = InjectionObserver()

    public init() {}

    public var wrappedValue: Int { observer.injectionCount }
}

extension View {
    /// Wraps the view in AnyView to enable hot-reload via symbol interposition.
    ///
    /// SwiftUI normally dispatches `body` through protocol witness tables (direct pointers).
    /// AnyView type-erases the view, forcing SwiftUI to call `body` through an existential
    /// container that uses indirect dispatch — making it rebindable via `-interposable` stubs.
    ///
    /// This is the same technique used by InjectionIII/HotSwiftUI.
    public func enableInjection() -> some View {
        AnyView(self)
    }
}

#endif

#endif

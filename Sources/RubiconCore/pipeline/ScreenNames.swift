import Foundation

/// The naming rules of automatic screen views (Lifecycle 3, iOS Lifecycle 2): a name declared in
/// code, else the class name without its module prefix and without `ViewController`; never the
/// title. The platform target resolves the controller; the rules live here, tested with plain
/// strings.
package enum ScreenNames {
    package static let nameSource = "name_source"
    /// A name declared in code (`ScreenNamed`, the counterpart of `@ScreenName`).
    package static let declared = "annotation"
    /// A name derived from the class.
    package static let fromClass = "class"

    private static let suffix = "ViewController"

    /// `MyApp.SettingsViewController` becomes `Settings`; a class named `ViewController` keeps its
    /// name rather than becoming empty; a name longer than the limit is left to the pipeline's rule.
    package static func name(forClass typeName: String) -> String {
        var name = typeName
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        if name.hasSuffix(suffix) && name.count > suffix.count { name.removeLast(suffix.count) }
        return name
    }
}

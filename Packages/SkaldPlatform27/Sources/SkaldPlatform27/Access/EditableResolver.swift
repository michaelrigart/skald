import ApplicationServices

/// A focused web area to its editable field, or none: the editable ancestor of the element at the selection's
/// start (Mail's compose web area is its own). A page being read has none, so it is never checked.
enum EditableResolver {
    static let editableAncestorAttribute = "AXEditableAncestor"

    static func resolve<Element, Marker>(
        role: String?, focused: Element, selectionStart: () -> Marker?, element: (Marker) -> Element?,
        editableAncestor: (Element) -> Element?
    ) -> Element? {
        guard role == TextAccessRules.webAreaRole else { return focused }
        guard let marker = selectionStart(), let leaf = element(marker) else { return nil }
        return editableAncestor(leaf)
    }

    /// Called on `AXQueue` only.
    static func field(for focused: AXElement) -> AXElement? {
        resolve(
            role: focused.role, focused: focused,
            selectionStart: { TextMarkerField.selectionStart(of: focused) },
            element: { TextMarkerField.axElement(focused.parameterized("AXUIElementForTextMarker", $0)) },
            editableAncestor: { $0.elementAttribute(editableAncestorAttribute) }
        )
    }
}

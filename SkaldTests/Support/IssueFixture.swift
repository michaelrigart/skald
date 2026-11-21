import Foundation
import SkaldCore

/// An issue on a one-paragraph field holding `text`, for the edit that turns `text` into `revised`.
func issue(in text: String, revised: String, at location: Int = 0, source: IssueSource = .model) -> Issue {
    let field = FieldID(app: "com.example.editor", token: "field-1")
    let paragraph = Paragraph(range: TextRange(location: location, length: text.utf16.count), text: text)
    guard let edit = TextDiff.edits(from: text, to: revised).first else { fatalError("no edit between the texts") }
    return Issue(
        key: ParagraphKey(field: field, text: text, position: .occurrence(0), chunk: 0),
        parent: paragraph, chunk: paragraph, edit: edit, source: source, language: .en
    )
}

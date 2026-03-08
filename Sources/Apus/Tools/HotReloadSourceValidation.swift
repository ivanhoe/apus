#if DEBUG
import Foundation

/// Fast source-level guardrails for hot reload.
///
/// This intentionally uses lightweight declaration-pattern detection
/// (not a full Swift parser) to avoid expensive validation in the save loop.
struct HotReloadSourceValidation {
    let isInjectable: Bool
    let reasonCodes: [String]
    let details: [String]
}

enum HotReloadSourceValidator {
    static let referenceTypeReasonCode = "HR_SOURCE_CONTAINS_REFERENCE_TYPES"
    static let mainEntryReasonCode = "HR_SOURCE_CONTAINS_MAIN_ENTRY"

    static func validate(sourceCode: String, originalPath: String?) -> HotReloadSourceValidation {
        guard !sourceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return HotReloadSourceValidation(
                isInjectable: true,
                reasonCodes: [],
                details: []
            )
        }

        var reasonCodes: [String] = []
        var details: [String] = []

        if hasReferenceTypeDeclarations(in: sourceCode) {
            reasonCodes.append(referenceTypeReasonCode)
            details.append("Detected class/actor/protocol declaration; these changes are not reliably hot-reloadable.")
        }

        if hasMainAttribute(in: sourceCode) {
            reasonCodes.append(mainEntryReasonCode)
            details.append("Detected @main entry point; app lifecycle changes require build/deploy.")
        }

        if let originalPath, !originalPath.isEmpty, !reasonCodes.isEmpty {
            details.append("original_path: \(originalPath)")
        }

        return HotReloadSourceValidation(
            isInjectable: reasonCodes.isEmpty,
            reasonCodes: reasonCodes,
            details: details
        )
    }

    static func formatRejectionMessage(
        validation: HotReloadSourceValidation,
        originalPath: String?
    ) -> String {
        let codes = validation.reasonCodes.joined(separator: ",")
        let detailText = validation.details.joined(separator: " ")
        var message = "Hot reload rejected source as non-injectable. reason_codes=[\(codes)]."
        if !detailText.isEmpty {
            message += " \(detailText)"
        }
        message += " Use preview_changes/build+deploy for this edit."
        if let originalPath, !originalPath.isEmpty {
            message += " (HR path: \(originalPath))"
        }
        return message
    }

    private static func hasReferenceTypeDeclarations(in sourceCode: String) -> Bool {
        let cleaned = sanitizeSource(sourceCode)
        // Match declarations at line-start to reduce false positives in inline text.
        // Supports common modifiers such as `final class`, `public actor`, etc.
        let pattern = #"(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|open|final|indirect|nonisolated|dynamic|override)\s+)*(class|actor|protocol)\s+[A-Za-z_][A-Za-z0-9_]*\b"#
        return declarationRegex(pattern: pattern)?
            .firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)) != nil
    }

    private static func hasMainAttribute(in sourceCode: String) -> Bool {
        let cleaned = sanitizeSource(sourceCode)
        return declarationRegex(pattern: #"(?m)^\s*@main\b"#)?
            .firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)) != nil
    }

    private static func declarationRegex(pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }

    private static func sanitizeSource(_ sourceCode: String) -> String {
        let noBlockComments = sourceCode.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return noBlockComments.replacingOccurrences(
            of: #"(?m)//.*$"#,
            with: "",
            options: .regularExpression
        )
    }
}
#endif

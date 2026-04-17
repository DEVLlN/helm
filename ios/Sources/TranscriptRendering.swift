import Foundation
import SwiftUI

enum TranscriptMessageRole: Equatable {
    case assistant
    case user
    case pendingUser
}

private protocol TranscriptTextProcessor {
    func process(_ text: String) -> String
}

private struct NormalizeWhitespaceProcessor: TranscriptTextProcessor {
    func process(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

private struct AutolinkProcessor: TranscriptTextProcessor {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    func process(_ text: String) -> String {
        guard let detector = Self.detector else { return text }

        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            guard
                let range = Range(match.range, in: output),
                let url = match.url?.absoluteString
            else {
                continue
            }

            let original = String(output[range])
            if original.contains("](") || original.hasPrefix("[") || original.hasPrefix("http") == false {
                continue
            }
            output.replaceSubrange(range, with: "[\(original)](\(url))")
        }
        return output
    }
}

enum TranscriptBlock: Identifiable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([TranscriptListItem])
    case code(language: String?, content: String)
    case latexBlock(String)
    case blockquote(String)
    case thematicBreak

    var id: String {
        switch self {
        case .heading(let level, let text):
            return "heading|\(level)|\(text.hashValue)"
        case .paragraph(let text):
            return "paragraph|\(text.hashValue)"
        case .list(let items):
            return "list|\(items.map(\.id).joined(separator: "|"))"
        case .code(let language, let content):
            return "code|\(language ?? "_")|\(content.hashValue)"
        case .latexBlock(let text):
            return "latex|\(text.hashValue)"
        case .blockquote(let text):
            return "blockquote|\(text.hashValue)"
        case .thematicBreak:
            return "thematicBreak"
        }
    }

    var revealLength: Int {
        switch self {
        case .heading(_, let text),
             .paragraph(let text),
             .latexBlock(let text),
             .blockquote(let text):
            return text.count
        case .list(let items):
            return items.map(\.revealLength).reduce(0, +)
        case .code(_, let content):
            return content.count
        case .thematicBreak:
            return 1
        }
    }
}

struct TranscriptListItem: Identifiable, Equatable {
    let marker: String
    var text: String

    var id: String {
        "\(marker)|\(text.hashValue)"
    }

    var revealLength: Int {
        text.count
    }
}

struct TranscriptPositionedBlock: Identifiable, Equatable {
    let block: TranscriptBlock
    let start: Int
    let end: Int

    var id: String {
        "\(start)|\(block.id)"
    }

    var revealLength: Int {
        max(0, end - start)
    }

    func localRevealPosition(for globalRevealPosition: Double) -> Double {
        min(max(globalRevealPosition - Double(start), 0), Double(revealLength))
    }
}

struct TranscriptPositionedListItem: Identifiable, Equatable {
    let item: TranscriptListItem
    let start: Int
    let end: Int

    var id: String {
        "\(start)|\(item.id)"
    }

    var revealLength: Int {
        max(0, end - start)
    }

    func localRevealPosition(for listRevealPosition: Double) -> Double {
        min(max(listRevealPosition - Double(start), 0), Double(revealLength))
    }
}

enum TranscriptBlockLayout {
    static func position(_ blocks: [TranscriptBlock]) -> [TranscriptPositionedBlock] {
        var offset = 0
        return blocks.map { block in
            let start = offset
            let end = start + block.revealLength
            offset = end
            return TranscriptPositionedBlock(block: block, start: start, end: end)
        }
    }

    static func position(_ items: [TranscriptListItem]) -> [TranscriptPositionedListItem] {
        var offset = 0
        return items.map { item in
            let start = offset
            let end = start + item.revealLength
            offset = end
            return TranscriptPositionedListItem(item: item, start: start, end: end)
        }
    }
}

enum TranscriptInlineSegment: Equatable {
    case markdown(String)
    case latex(String)
}

enum TranscriptInlineLatexParser {
    static func segments(from text: String) -> [TranscriptInlineSegment] {
        var segments: [TranscriptInlineSegment] = []
        var markdownStart = text.startIndex
        var index = text.startIndex

        func appendMarkdown(upTo end: String.Index) {
            guard markdownStart < end else { return }
            segments.append(.markdown(String(text[markdownStart..<end])))
        }

        while index < text.endIndex {
            if text[index] == "$",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] != "$",
               let end = text[text.index(after: index)...].firstIndex(of: "$") {
                appendMarkdown(upTo: index)
                let contentStart = text.index(after: index)
                segments.append(.latex(String(text[contentStart..<end])))
                index = text.index(after: end)
                markdownStart = index
                continue
            }

            if text[index] == "\\",
               text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "(",
               let end = text.range(of: "\\)", range: text.index(index, offsetBy: 2)..<text.endIndex) {
                appendMarkdown(upTo: index)
                let contentStart = text.index(index, offsetBy: 2)
                segments.append(.latex(String(text[contentStart..<end.lowerBound])))
                index = end.upperBound
                markdownStart = index
                continue
            }

            index = text.index(after: index)
        }

        appendMarkdown(upTo: text.endIndex)
        return coalesced(segments)
    }

    private static func coalesced(_ segments: [TranscriptInlineSegment]) -> [TranscriptInlineSegment] {
        var output: [TranscriptInlineSegment] = []
        for segment in segments {
            switch (output.last, segment) {
            case (.markdown(let existing), .markdown(let next)):
                output[output.count - 1] = .markdown(existing + next)
            case (.latex(let existing), .latex(let next)):
                output[output.count - 1] = .latex(existing + next)
            default:
                output.append(segment)
            }
        }
        return output
    }
}

private struct TranscriptBubbleTheme {
    let foreground: Color
    let mutedForeground: Color
    let accent: Color
    let codeBackground: Color
    let codeBorder: Color
}

private enum TranscriptThemes {
    static func theme(
        backendId: String?,
        role: TranscriptMessageRole
    ) -> TranscriptBubbleTheme {
        switch role {
        case .user:
            return TranscriptBubbleTheme(
                foreground: AppPalette.primaryText,
                mutedForeground: AppPalette.secondaryText,
                accent: AppPalette.accent,
                codeBackground: AppPalette.accent.opacity(0.06),
                codeBorder: AppPalette.accent.opacity(0.16)
            )
        case .pendingUser:
            return TranscriptBubbleTheme(
                foreground: AppPalette.primaryText,
                mutedForeground: AppPalette.secondaryText,
                accent: AppPalette.accent,
                codeBackground: AppPalette.mutedPanel,
                codeBorder: AppPalette.border
            )
        case .assistant:
            let accent: Color
            if backendId == "claude-code" {
                accent = .orange
            } else {
                accent = .green
            }
            return TranscriptBubbleTheme(
                foreground: AppPalette.primaryText,
                mutedForeground: AppPalette.secondaryText,
                accent: accent,
                codeBackground: AppPalette.mutedPanel.opacity(0.7),
                codeBorder: AppPalette.border
            )
        }
    }
}

enum TranscriptSemanticTextRole: Hashable {
    case primary
    case muted
    case accent
    case command
    case option
    case literal
    case success
    case danger
    case path
}

struct TranscriptSemanticTextRun: Hashable {
    let text: String
    let role: TranscriptSemanticTextRole
}

enum TranscriptSemanticHighlighter {
    static func runs(for text: String) -> [TranscriptSemanticTextRun] {
        var runs: [TranscriptSemanticTextRun] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace {
                let start = index
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
                runs.append(TranscriptSemanticTextRun(text: String(text[start..<index]), role: .primary))
                continue
            }

            if character == "`" {
                let start = text.index(after: index)
                index = start
                while index < text.endIndex, text[index] != "`" {
                    index = text.index(after: index)
                }
                let literal = String(text[start..<index])
                if index < text.endIndex {
                    index = text.index(after: index)
                }
                runs.append(TranscriptSemanticTextRun(text: literal, role: role(forLiteral: literal)))
                continue
            }

            let start = index
            while index < text.endIndex,
                  !text[index].isWhitespace,
                  text[index] != "`" {
                index = text.index(after: index)
            }
            let token = String(text[start..<index])
            runs.append(TranscriptSemanticTextRun(text: token, role: role(forToken: token)))
        }

        return coalescedRuns(runs)
    }

    private static func role(forLiteral literal: String) -> TranscriptSemanticTextRole {
        if isPathLike(literal) {
            return .path
        }
        if isCommandLike(literal) {
            return .command
        }
        return .literal
    }

    private static func role(forToken token: String) -> TranscriptSemanticTextRole {
        let normalized = token
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}<>\"'"))
        let lower = normalized.lowercased()

        if normalized.isEmpty {
            return .primary
        }
        if isOperationWord(normalized) {
            return .accent
        }
        if normalized.hasPrefix("-") {
            return .option
        }
        if isSuccessWord(lower) {
            return .success
        }
        if isDangerWord(lower) {
            return .danger
        }
        if isCommitLike(normalized) || isPathLike(normalized) {
            return .path
        }
        if isCommandLike(normalized) {
            return .command
        }
        return .primary
    }

    private static func isOperationWord(_ text: String) -> Bool {
        [
            "Ran",
            "Read",
            "List",
            "Search",
            "Explored",
            "Exploring",
            "Edited",
            "Tasks",
            "Working",
            "Queued",
            "Active",
            "Recent",
        ].contains(text)
    }

    private static func isSuccessWord(_ lower: String) -> Bool {
        [
            "passed",
            "succeeded",
            "installed",
            "launched",
            "pushed",
            "clean",
            "verified",
            "committed",
            "completed",
            "landed",
        ].contains(lower)
    }

    private static func isDangerWord(_ lower: String) -> Bool {
        [
            "failed",
            "error",
            "warning",
            "blocked",
            "stuck",
            "missing",
        ].contains(lower)
    }

    private static func isCommandLike(_ text: String) -> Bool {
        [
            "git",
            "xcodebuild",
            "xcrun",
            "codex",
            "claude",
            "helm",
            "sed",
            "rg",
            "swift",
            "swiftc",
        ].contains(text)
    }

    private static func isPathLike(_ text: String) -> Bool {
        if text.contains("/") {
            return true
        }

        let knownSuffixes = [
            ".swift",
            ".md",
            ".ts",
            ".tsx",
            ".js",
            ".jsx",
            ".py",
            ".json",
            ".yaml",
            ".yml",
            ".sh",
            ".txt",
            ".xcodeproj",
            ".xcworkspace",
            ".xcresult",
        ]
        return knownSuffixes.contains { text.hasSuffix($0) }
    }

    private static func isCommitLike(_ text: String) -> Bool {
        guard (7...40).contains(text.count) else { return false }
        let hexCharacters = Set("0123456789abcdef")
        return text.lowercased().allSatisfy { hexCharacters.contains($0) }
    }

    private static func coalescedRuns(_ runs: [TranscriptSemanticTextRun]) -> [TranscriptSemanticTextRun] {
        var output: [TranscriptSemanticTextRun] = []
        for run in runs {
            guard !run.text.isEmpty else { continue }
            if let last = output.last, last.role == run.role {
                output[output.count - 1] = TranscriptSemanticTextRun(
                    text: last.text + run.text,
                    role: run.role
                )
            } else {
                output.append(run)
            }
        }
        return output
    }
}

enum TranscriptSemanticHighlightingPolicy {
    static func shouldHighlight(
        _ markdown: String,
        role: TranscriptMessageRole,
        animateText: Bool
    ) -> Bool {
        guard role == .assistant, !animateText else { return false }
        guard !markdown.contains("]("),
              !markdown.contains("!["),
              !markdown.contains("**"),
              !markdown.contains("*"),
              !markdown.contains("$"),
              !markdown.contains("\\(") else {
            return false
        }

        return TranscriptSemanticHighlighter
            .runs(for: markdown)
            .contains { $0.role != .primary }
    }
}

private final class TranscriptPositionedBlockCacheEntry: NSObject {
    let value: [TranscriptPositionedBlock]

    init(_ value: [TranscriptPositionedBlock]) {
        self.value = value
    }
}

private enum TranscriptBlockCache {
    nonisolated(unsafe) private static let positionedBlocksCache: NSCache<NSString, TranscriptPositionedBlockCacheEntry> = {
        let cache = NSCache<NSString, TranscriptPositionedBlockCacheEntry>()
        cache.countLimit = 256
        cache.totalCostLimit = 1_200_000
        return cache
    }()

    static func positionedBlocks(for text: String, build: () -> [TranscriptPositionedBlock]) -> [TranscriptPositionedBlock] {
        let key = text as NSString
        if let cached = positionedBlocksCache.object(forKey: key) {
            return cached.value
        }
        let value = build()
        let cost = max(text.utf16.count, value.count * 24)
        positionedBlocksCache.setObject(TranscriptPositionedBlockCacheEntry(value), forKey: key, cost: cost)
        return value
    }
}

private enum TranscriptTypography {
    static func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 15, weight: .semibold, design: .rounded)
        case 2:
            return .system(size: 14, weight: .semibold, design: .rounded)
        default:
            return .system(size: 13, weight: .semibold, design: .rounded)
        }
    }

    static func headingLineSpacing(level: Int) -> CGFloat {
        level <= 2 ? 2 : 1
    }

    static func bodyFont(for role: TranscriptMessageRole, weight: Font.Weight = .regular) -> Font {
        switch role {
        case .assistant, .user, .pendingUser:
            return .system(size: 12, weight: weight, design: .monospaced)
        }
    }

    static func bodyLineSpacing(for role: TranscriptMessageRole) -> CGFloat {
        switch role {
        case .assistant:
            return 2
        case .user, .pendingUser:
            return 2
        }
    }

    static let inlineLatexFont: Font = .system(size: 12, design: .serif)
    static let blockLatexFont: Font = .system(size: 12, design: .serif)
    static let codeLabelFont: Font = .system(size: 10, weight: .semibold, design: .monospaced)
    static let codeLineFont: Font = .system(size: 11, design: .monospaced)
}

struct TranscriptMessageBubble: View, Equatable {
    let text: String
    let role: TranscriptMessageRole
    let backendId: String?
    var animateText = false

    @State private var revealPosition: Double = 0
    @State private var previousText = ""

    private let processors: [TranscriptTextProcessor] = [
        NormalizeWhitespaceProcessor(),
        AutolinkProcessor(),
    ]

    private var theme: TranscriptBubbleTheme {
        TranscriptThemes.theme(backendId: backendId, role: role)
    }

    nonisolated static func == (lhs: TranscriptMessageBubble, rhs: TranscriptMessageBubble) -> Bool {
        lhs.text == rhs.text &&
            lhs.role == rhs.role &&
            lhs.backendId == rhs.backendId &&
            lhs.animateText == rhs.animateText
    }

    private var positionedBlocks: [TranscriptPositionedBlock] {
        TranscriptBlockCache.positionedBlocks(for: text) {
            TranscriptBlockLayout.position(splitIntoBlocks(text))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(positionedBlocks) { positionedBlock in
                let localRevealPosition = animateText
                    ? positionedBlock.localRevealPosition(for: revealPosition)
                    : Double(positionedBlock.revealLength)

                if shouldRender(positionedBlock, localRevealPosition: localRevealPosition) {
                    switch positionedBlock.block {
                    case .heading(let level, let blockText):
                        headingBlock(
                            level: level,
                            text: processedMarkdown(blockText),
                            localRevealPosition: localRevealPosition
                        )
                    case .paragraph(let blockText):
                        paragraphBlock(processedMarkdown(blockText), localRevealPosition: localRevealPosition)
                    case .list(let items):
                        listBlock(items, localRevealPosition: localRevealPosition)
                    case .code(let language, let content):
                        let visibleContent = visiblePrefix(content, revealPosition: localRevealPosition)
                        TranscriptCodeBlockCard(
                            content: visibleContent,
                            language: language,
                            accent: theme.accent,
                            background: theme.codeBackground,
                            border: theme.codeBorder
                        )
                    case .latexBlock(let content):
                        latexBlock(content, localRevealPosition: localRevealPosition)
                    case .blockquote(let content):
                        blockquoteBlock(processedMarkdown(content), localRevealPosition: localRevealPosition)
                    case .thematicBreak:
                        thematicBreakBlock
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .task(id: text) {
            await animateRevealIfNeeded()
        }
    }

    @ViewBuilder
    private func headingBlock(level: Int, text: String, localRevealPosition: Double) -> some View {
        latexAwareText(text)
            .font(TranscriptTypography.headingFont(level: level))
            .textRenderer(TranscriptRolloutTextRenderer(revealPosition: localRevealPosition))
            .lineSpacing(TranscriptTypography.headingLineSpacing(level: level))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func paragraphBlock(_ markdown: String, localRevealPosition: Double) -> some View {
        transcriptText(markdown)
            .font(TranscriptTypography.bodyFont(for: role))
            .textRenderer(TranscriptRolloutTextRenderer(revealPosition: localRevealPosition))
            .lineSpacing(TranscriptTypography.bodyLineSpacing(for: role))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func listBlock(_ items: [TranscriptListItem], localRevealPosition: Double) -> some View {
        let positionedItems = TranscriptBlockLayout.position(items)

        return VStack(alignment: .leading, spacing: 5) {
            ForEach(positionedItems) { positionedItem in
                let itemRevealPosition = positionedItem.localRevealPosition(for: localRevealPosition)
                if !animateText || itemRevealPosition > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(positionedItem.item.marker)
                            .font(TranscriptTypography.bodyFont(for: role, weight: .semibold))
                            .foregroundStyle(theme.accent)

                        transcriptText(processedMarkdown(positionedItem.item.text))
                            .font(TranscriptTypography.bodyFont(for: role))
                            .textRenderer(TranscriptRolloutTextRenderer(revealPosition: itemRevealPosition))
                            .lineSpacing(TranscriptTypography.bodyLineSpacing(for: role))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func latexBlock(_ content: String, localRevealPosition: Double) -> some View {
        Text(verbatim: content)
            .font(TranscriptTypography.blockLatexFont)
            .italic()
            .foregroundColor(theme.accent)
            .multilineTextAlignment(.center)
            .textRenderer(TranscriptRolloutTextRenderer(revealPosition: localRevealPosition))
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(theme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func blockquoteBlock(_ markdown: String, localRevealPosition: Double) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(theme.accent.opacity(0.65))
                .frame(width: 2)

            transcriptText(markdown)
                .font(TranscriptTypography.bodyFont(for: role))
                .foregroundColor(theme.mutedForeground)
                .textRenderer(TranscriptRolloutTextRenderer(revealPosition: localRevealPosition))
                .lineSpacing(TranscriptTypography.bodyLineSpacing(for: role))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thematicBreakBlock: some View {
        Rectangle()
            .fill(AppPalette.border.opacity(0.72))
            .frame(height: 1)
            .padding(.vertical, 5)
    }

    private func processedMarkdown(_ text: String) -> String {
        processors.reduce(text) { partial, processor in
            processor.process(partial)
        }
    }

    private func markdownText(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return Text(attributed)
        }
        return Text(markdown)
    }

    private func latexAwareText(_ markdown: String) -> Text {
        let segments = TranscriptInlineLatexParser.segments(from: markdown)
        guard segments.count > 1 || (segments.first.map {
            if case .latex = $0 { return true }
            return false
        } ?? false) else {
            return markdownText(markdown).foregroundColor(theme.foreground)
        }

        return segments.reduce(Text(verbatim: "")) { partial, segment in
            switch segment {
            case .markdown(let text):
                return partial + markdownText(text).foregroundColor(theme.foreground)
            case .latex(let latex):
                return partial + Text(verbatim: latex)
                    .font(TranscriptTypography.inlineLatexFont)
                    .italic()
                    .foregroundColor(theme.accent)
            }
        }
    }

    private func transcriptText(_ markdown: String) -> Text {
        guard TranscriptSemanticHighlightingPolicy.shouldHighlight(
            markdown,
            role: role,
            animateText: animateText
        ) else {
            return latexAwareText(markdown)
        }

        let runs = TranscriptSemanticHighlighter.runs(for: markdown)
        return runs.reduce(Text(verbatim: "")) { partial, run in
            partial + Text(verbatim: run.text).foregroundColor(color(for: run.role))
        }
    }

    private func shouldRender(
        _ block: TranscriptPositionedBlock,
        localRevealPosition: Double
    ) -> Bool {
        !animateText || localRevealPosition > 0 || block.revealLength == 0
    }

    private func visiblePrefix(_ content: String, revealPosition: Double) -> String {
        guard animateText else { return content }
        let count = min(content.count, max(0, Int(ceil(revealPosition))))
        return String(content.prefix(count))
    }

    private func color(for role: TranscriptSemanticTextRole) -> Color {
        switch role {
        case .primary:
            return theme.foreground
        case .muted:
            return theme.mutedForeground
        case .accent, .command:
            return theme.accent
        case .option:
            return .pink
        case .literal, .success:
            return .green
        case .danger:
            return AppPalette.danger
        case .path:
            return .cyan
        }
    }

    private func splitIntoBlocks(_ text: String) -> [TranscriptBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [TranscriptBlock] = []
        var markdownBuffer: [String] = []
        var codeBuffer: [String] = []
        var codeLanguage: String?
        var insideCodeFence = false

        func flushMarkdownBuffer() {
            let markdown = markdownBuffer.joined(separator: "\n")
            blocks.append(contentsOf: splitMarkdownBlocks(markdown))
            markdownBuffer.removeAll(keepingCapacity: true)
        }

        func flushCodeBuffer() {
            let code = codeBuffer.joined(separator: "\n")
            if !code.isEmpty {
                blocks.append(.code(language: codeLanguage, content: code))
            }
            codeBuffer.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for line in lines {
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if insideCodeFence {
                    flushCodeBuffer()
                    insideCodeFence = false
                } else {
                    flushMarkdownBuffer()
                    insideCodeFence = true
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if insideCodeFence {
                codeBuffer.append(line)
            } else {
                markdownBuffer.append(line)
            }
        }

        if insideCodeFence {
            flushCodeBuffer()
        } else {
            flushMarkdownBuffer()
        }

        if blocks.isEmpty, !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return splitMarkdownBlocks(normalized)
        }

        return blocks
    }

    private func splitMarkdownBlocks(_ text: String) -> [TranscriptBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var blocks: [TranscriptBlock] = []
        var paragraphBuffer: [String] = []
        var listBuffer: [TranscriptListItem] = []
        var blockquoteBuffer: [String] = []
        var latexBuffer: [String] = []
        var latexEndDelimiter: String?

        func flushParagraphBuffer() {
            let paragraph = paragraphBuffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
            }
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        func flushListBuffer() {
            guard !listBuffer.isEmpty else { return }
            blocks.append(.list(listBuffer))
            listBuffer.removeAll(keepingCapacity: true)
        }

        func flushBlockquoteBuffer() {
            let blockquote = blockquoteBuffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !blockquote.isEmpty {
                blocks.append(.blockquote(blockquote))
            }
            blockquoteBuffer.removeAll(keepingCapacity: true)
        }

        func flushLatexBuffer() {
            let latex = latexBuffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !latex.isEmpty {
                blocks.append(.latexBlock(latex))
            }
            latexBuffer.removeAll(keepingCapacity: true)
            latexEndDelimiter = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let latexEndDelimiter {
                if let endRange = line.range(of: latexEndDelimiter) {
                    latexBuffer.append(String(line[..<endRange.lowerBound]))
                    flushLatexBuffer()
                } else {
                    latexBuffer.append(line)
                }
                continue
            }

            if trimmed.isEmpty {
                flushParagraphBuffer()
                flushListBuffer()
                flushBlockquoteBuffer()
                continue
            }

            if let latex = singleLineLatexBlock(from: trimmed) {
                flushParagraphBuffer()
                flushListBuffer()
                flushBlockquoteBuffer()
                blocks.append(.latexBlock(latex))
                continue
            }

            if let start = latexBlockStart(in: trimmed) {
                flushParagraphBuffer()
                flushListBuffer()
                flushBlockquoteBuffer()
                latexEndDelimiter = start.endDelimiter
                latexBuffer.append(start.initialContent)
                continue
            }

            if let heading = headingBlock(for: trimmed) {
                flushParagraphBuffer()
                flushListBuffer()
                flushBlockquoteBuffer()
                blocks.append(heading)
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraphBuffer()
                flushListBuffer()
                flushBlockquoteBuffer()
                blocks.append(.thematicBreak)
                continue
            }

            if let blockquote = blockquoteLine(for: line) {
                flushParagraphBuffer()
                flushListBuffer()
                blockquoteBuffer.append(blockquote)
                continue
            }

            if let item = listItem(for: line) {
                flushParagraphBuffer()
                flushBlockquoteBuffer()
                listBuffer.append(item)
                continue
            }

            if !listBuffer.isEmpty, line.first?.isWhitespace == true {
                let continuation = trimmed
                if !continuation.isEmpty {
                    listBuffer[listBuffer.count - 1].text += "\n\(continuation)"
                }
                continue
            }

            flushListBuffer()
            flushBlockquoteBuffer()
            paragraphBuffer.append(line)
        }

        if latexEndDelimiter != nil {
            flushLatexBuffer()
        }
        flushParagraphBuffer()
        flushListBuffer()
        flushBlockquoteBuffer()

        return blocks
    }

    private func headingBlock(for line: String) -> TranscriptBlock? {
        guard line.first == "#" else { return nil }
        let marker = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(marker.count),
              marker.count < line.count else { return nil }
        let contentStart = line.index(line.startIndex, offsetBy: marker.count)
        guard line[contentStart] == " " else { return nil }
        let title = String(line[line.index(after: contentStart)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return .heading(level: marker.count, text: title)
    }

    private func blockquoteLine(for line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        return String(trimmed.dropFirst())
            .trimmingCharacters(in: .whitespaces)
    }

    private func isThematicBreak(_ line: String) -> Bool {
        let characters = line.filter { !$0.isWhitespace }
        guard characters.count >= 3 else { return false }
        return characters.allSatisfy { $0 == "-" }
            || characters.allSatisfy { $0 == "*" }
            || characters.allSatisfy { $0 == "_" }
    }

    private func singleLineLatexBlock(from line: String) -> String? {
        if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if line.hasPrefix("\\["), line.hasSuffix("\\]"), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func latexBlockStart(in line: String) -> (initialContent: String, endDelimiter: String)? {
        if line.hasPrefix("$$") {
            return (
                String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines),
                "$$"
            )
        }
        if line.hasPrefix("\\[") {
            return (
                String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines),
                "\\]"
            )
        }
        return nil
    }

    private func listItem(for line: String) -> TranscriptListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return TranscriptListItem(
                marker: "\u{2022}",
                text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            )
        }

        var digitsEnd = trimmed.startIndex
        while digitsEnd < trimmed.endIndex, trimmed[digitsEnd].isNumber {
            digitsEnd = trimmed.index(after: digitsEnd)
        }

        guard digitsEnd > trimmed.startIndex, digitsEnd < trimmed.endIndex else {
            return nil
        }

        let punctuation = trimmed[digitsEnd]
        guard punctuation == "." || punctuation == ")" else {
            return nil
        }

        let afterPunctuation = trimmed.index(after: digitsEnd)
        guard afterPunctuation < trimmed.endIndex, trimmed[afterPunctuation] == " " else {
            return nil
        }

        let marker = String(trimmed[..<digitsEnd]) + "."
        let textStart = trimmed.index(after: afterPunctuation)
        return TranscriptListItem(
            marker: marker,
            text: String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
        )
    }

    @MainActor
    private func animateRevealIfNeeded() async {
        guard animateText else {
            revealPosition = Double(text.count)
            previousText = text
            return
        }

        let targetPosition = Double(text.count)
        if previousText.isEmpty || text.hasPrefix(previousText) {
            revealPosition = min(revealPosition, targetPosition)
        } else {
            revealPosition = 0
        }

        let frameInterval = 1.0 / 60.0
        let timeConstant = 0.14
        let alpha = 1.0 - exp(-frameInterval / timeConstant)

        while revealPosition < targetPosition {
            let remaining = targetPosition - revealPosition
            let step = max(remaining * alpha, min(1.0, remaining))
            revealPosition = min(targetPosition, revealPosition + step)
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
        }

        revealPosition = targetPosition
        previousText = text
    }
}

struct TranscriptRolloutTextRenderer: TextRenderer {
    let revealPosition: Double
    var fadeWidth = 8

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var characterIndex = 0

        for line in layout {
            for run in line {
                for slice in run {
                    defer { characterIndex += 1 }

                    let characterDistance = revealPosition - Double(characterIndex)
                    guard characterDistance > 0 else { continue }

                    var copy = context
                    if characterDistance < Double(fadeWidth) {
                        copy.opacity = max(0.18, min(1.0, characterDistance / Double(fadeWidth)))
                    }
                    copy.draw(slice)
                }
            }
        }
    }
}

struct TranscriptCodeBlockCard: View {
    let content: String
    let language: String?
    let accent: Color
    let background: Color
    let border: Color
    var maxVisibleLines: Int? = nil
    var showsOverflowIndicator = false

    private var lines: [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    private var visibleLines: [String] {
        guard let maxVisibleLines, maxVisibleLines > 0 else {
            return lines
        }
        return Array(lines.prefix(maxVisibleLines))
    }

    private var languageLabel: String {
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "code" : trimmed
    }

    private var showsLanguageLabel: Bool {
        let normalized = languageLabel.lowercased()
        return normalized != "code" && normalized != "shell" && normalized != "text"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLanguageLabel {
                HStack {
                    Text(languageLabel)
                        .font(TranscriptTypography.codeLabelFont)
                        .foregroundStyle(accent)

                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(visibleLines.enumerated()), id: \.offset) { entry in
                    Text(verbatim: entry.element)
                        .font(TranscriptTypography.codeLineFont)
                        .foregroundStyle(color(for: entry.element))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showsOverflowIndicator {
                    Text("…")
                        .font(TranscriptTypography.codeLineFont)
                        .foregroundStyle(AppPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(7)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(border.opacity(0.65), lineWidth: 1)
        )
    }

    private func color(for line: String) -> Color {
        if languageLabel == "diff" || line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix("@@") {
            if line.hasPrefix("+") {
                return .green
            }
            if line.hasPrefix("-") {
                return AppPalette.danger
            }
            if line.hasPrefix("@@") {
                return AppPalette.accent
            }
        }
        return AppPalette.primaryText
    }
}

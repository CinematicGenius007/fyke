// Generated text, drawn like an article: each claim is followed by the numbers of the
// articles it cites, and every number is one hover from its source.
import ReaderLogic
import SwiftUI

/// Lays out views left to right and wraps them like words in a paragraph.
struct Flow: Layout {
    var spacing: CGFloat = 0
    var lineHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Metrics.readingColumn
        var x: CGFloat = 0
        var lines: CGFloat = 1
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                lines += 1
                x = 0
            }
            x += size.width + spacing
        }
        return CGSize(width: width, height: lines * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight
            }
            view.place(at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2), proposal: .unspecified)
            x += size.width + spacing
        }
    }
}

/// Which citation is open, and where its number is.
struct CitationFocus: Equatable {
    let number: Int
    let anchor: CGRect
    var pinned = false
}

/// The sections of a brief or an answer.
struct BriefBody: View {
    let artifact: Artifact
    let focus: CitationFocus?
    /// A number was hovered or left, at a place in the "brief" space.
    var hover: (Int, Bool, CGRect) -> Void = { _, _, _ in }
    /// A number was clicked or activated with the keyboard.
    var pin: (Int, CGRect) -> Void = { _, _ in }
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily
    private var size: Double { min(Prefs.shared.ui.textSize, 21) }
    private var lineHeight: CGFloat { (size * Prefs.shared.ui.lineSpacing).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(artifact.sections.enumerated()), id: \.offset) { _, section in
                if let heading = section.heading, !heading.isEmpty {
                    Text(heading).font(.title(titleFamily, 22, .semibold))
                        .padding(.top, 12).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                }
                paragraph(section.claims).padding(.bottom, 24)
            }
        }
    }

    private func paragraph(_ claims: [Claim]) -> some View {
        Flow(lineHeight: lineHeight) {
            ForEach(Array(claims.enumerated()), id: \.offset) { index, claim in
                let words = claim.text.split(separator: " ")
                ForEach(Array(words.enumerated()), id: \.offset) { position, word in
                    // The last word keeps no trailing space when numbers follow it.
                    let spaced = position == words.count - 1 && !claim.sources.isEmpty ? String(word) : word + " "
                    Text(spaced).font(.reading(family, size)).foregroundStyle(p.ink)
                }
                ForEach(Array(claim.sources.enumerated()), id: \.offset) { position, number in
                    CitationMark(number: number, last: position == claim.sources.count - 1, active: focus?.number == number, hover: { hover(number, $0, $1) }, pin: { pin(number, $0) })
                }
                if !claim.sources.isEmpty { Text(" ").font(.reading(family, size)) }
                let _ = index
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(claims.map { claim in
            claim.text + (claim.sources.isEmpty ? "" : " Sources \(claim.sources.map(String.init).joined(separator: ", ")).")
        }.joined(separator: " "))
    }
}

/// A source number after a claim. Hovering shows the source; clicking keeps it open.
private struct CitationMark: View {
    let number: Int
    let last: Bool
    let active: Bool
    let hover: (Bool, CGRect) -> Void
    let pin: (CGRect) -> Void
    @State private var frame = CGRect.zero
    @State private var hovering = false
    @Environment(\.palette) private var p

    var body: some View {
        Button { pin(frame) } label: {
            Text(last ? "\(number)" : "\(number),").font(.ui(12, .semibold))
                .foregroundStyle(p.unread)
                .baselineOffset(5)
                .padding(.horizontal, 2)
                .background(hovering || active ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Radii.mark))
        }
        .buttonStyle(.bare)
        .frameIn("brief") { frame = $0 }
        .onHover { inside in
            hovering = inside
            hover(inside, frame)
        }
        .task { await PinForCheck.offer(number) { pin(frame) } }
        .accessibilityLabel("Source \(number)")
        .accessibilityHint("Shows the cited article")
    }
}

/// `FYKE_PIN_CITATION=N` pins the popover of source N once, as a click on its number
/// would, so that tools/e2e_gui.py can take a picture of it without a pointer.
@MainActor private enum PinForCheck {
    private static var done = false

    static func offer(_ number: Int, pin: () -> Void) async {
        guard !done, ProcessInfo.processInfo.environment["FYKE_PIN_CITATION"] == String(number) else { return }
        done = true
        // The number moves while the column's fonts and width settle.
        try? await Task.sleep(for: .seconds(1))
        pin()
    }
}

/// The source behind a number: where it is from, its title and its words.
struct CitationPopover: View {
    static let width: CGFloat = 340
    let citation: Citation
    let open: () -> Void
    let close: () -> Void
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily
    @Environment(\.readingFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(["\(citation.number)", citation.feedTitle, citation.date.map { Dates.relative($0) }].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(12)).foregroundStyle(p.muted).padding(.bottom, 4)
            Text(citation.title).font(.title(titleFamily, 17, .semibold))
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            if let snippet = citation.snippet, !snippet.isEmpty {
                Text("“\(snippet.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.reading(family, 14)).foregroundStyle(p.inkSoft).line(21, size: 14).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(p.unread).frame(width: 2) }
                    .padding(.bottom, 12)
            }
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 4) { Text("Open article"); Image(systemName: "return").font(.system(size: 10)) }
                }
                .buttonStyle(ActionStyle(kind: .quiet, height: Metrics.compactControl))
                .keyboardShortcut(.defaultAction)
                Text("Opens here, in the reader").font(.ui(12)).foregroundStyle(p.muted)
            }
            .padding(.leading, -10)
        }
        .padding(Metrics.panelEdge)
        .frame(width: CitationPopover.width, alignment: .leading)
        .popoverPanel()
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source \(citation.number): \(citation.title)")
    }
}

/// The numbered sources under a brief or an answer.
struct SourceList: View {
    let artifact: Artifact
    let open: (Int64) -> Void
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule().padding(.bottom, 20)
            SectionLabel(text: "Sources").padding(.bottom, 8)
            ForEach(artifact.citations) { citation in
                SourceRow(citation: citation) { open(citation.entryId) }
            }
            if let note = SourcesNote.text(omitted: Int(artifact.omittedCount), read: Int(artifact.inputCount), cited: artifact.citations.count) {
                Text(note).font(.ui(13)).foregroundStyle(p.muted).padding(.top, 8).padding(.leading, 28)
            }
        }
    }
}

private struct SourceRow: View {
    let citation: Citation
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var p
    @Environment(\.titleFamily) private var titleFamily

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(citation.number)").font(.ui(13, .medium)).foregroundStyle(p.unread).frame(width: 28, alignment: .leading)
                Text(citation.title).font(.title(titleFamily, 17, .medium))
                    .foregroundStyle(citation.read ? p.read : p.unread).lineLimit(1)
                    .underline(hovering)
                Spacer(minLength: 16)
                Text(citation.feedTitle ?? "").font(.ui(12)).foregroundStyle(p.muted).lineLimit(1)
            }
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bare)
        .onHover { hovering = $0 }
        .accessibilityLabel("Source \(citation.number), \(citation.title), \(citation.feedTitle ?? "")")
    }
}

/// "Written by Codex with your Morning brief recipe · rev 3", which opens the recipe.
struct MadeWith: View {
    let artifact: Artifact
    let recipeName: String?
    let openRecipe: () -> Void
    @Environment(\.palette) private var p

    private var writer: String {
        switch artifact.writer?.lowercased() {
        case "claude", "claude-code", "claude_code": "Claude Code"
        case "codex": "Codex"
        case let other?: other
        case nil: "a writer"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(p.inkSoft)
            (Text("Written by \(writer) with your ") + Text("\(recipeName ?? artifact.recipeName ?? "recipe")").fontWeight(.semibold)
                + Text(artifact.recipeRevision.map { " · rev \($0)" } ?? "") + Text(artifact.durationSeconds.map { " · \($0) s" } ?? ""))
                .font(.ui(13)).foregroundStyle(p.inkSoft).lineLimit(1)
            Spacer(minLength: 12)
            Button("Edit recipe", action: openRecipe).buttonStyle(ActionStyle(kind: .link, height: Metrics.compactControl))
        }
        .padding(.leading, Metrics.panelEdge).padding(.trailing, 8)
        .frame(height: Metrics.panelHeader)
        .background(p.surface, in: RoundedRectangle(cornerRadius: Radii.panel))
        .accessibilityElement(children: .contain)
    }
}

/// A brief or answer with its sources, and the popover that a citation opens.
struct ArtifactColumn<Header: View, Footer: View>: View {
    let artifact: Artifact
    let open: (Int64) -> Void
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer
    @State private var focus: CitationFocus?
    @State private var overPopover = false
    @State private var overMark = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                BriefBody(artifact: artifact, focus: focus, hover: { number, inside, frame in
                    overMark = inside
                    if inside {
                        if focus?.pinned != true { focus = CitationFocus(number: number, anchor: frame) }
                    } else {
                        closeSoon()
                    }
                }, pin: { number, frame in
                    focus = focus?.number == number && focus?.pinned == true ? nil : CitationFocus(number: number, anchor: frame, pinned: true)
                })
                SourceList(artifact: artifact, open: open).padding(.top, 8).padding(.bottom, 32)
                footer
            }
            .frame(maxWidth: Metrics.readingColumn, alignment: .leading)
            .padding(.horizontal, Metrics.pageGutter).padding(.top, 72).padding(.bottom, 96)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named("brief"))
            .overlay(alignment: .topLeading) { popover }
        }
        .themedScrollbar()
        .onChange(of: artifact.id) { focus = nil }
    }

    @ViewBuilder private var popover: some View {
        if let focus, let citation = artifact.citations.first(where: { $0.number == focus.number }) {
            CitationPopover(citation: citation, open: {
                self.focus = nil
                open(citation.entryId)
            }, close: { self.focus = nil })
            .offset(x: min(focus.anchor.minX - Metrics.panelEdge, Metrics.readingColumn + Metrics.pageGutter - CitationPopover.width), y: focus.anchor.maxY + 4)
            .onHover { inside in
                overPopover = inside
                if !inside { closeSoon() }
            }
            .transition(.opacity)
        }
    }

    /// Leaving a number for its popover crosses a gap, so closing waits a moment.
    private func closeSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !overPopover && !overMark && focus?.pinned == false { focus = nil }
        }
    }
}

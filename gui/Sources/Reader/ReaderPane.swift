import SwiftUI

struct ReaderPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily
    @Environment(FloatLayer.self) private var layer
    @State private var typeFrame = CGRect.zero

    private var columnWidth: Double { Prefs.shared.ui.columnWidth }
    private var textSize: Double { Prefs.shared.ui.textSize }
    private var spacing: Double { Prefs.shared.ui.lineSpacing }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let web = model.web {
                WebPane(state: web).id(ObjectIdentifier(web))
            } else if let article = model.article {
                ScrollView {
                    column(article)
                        .frame(maxWidth: columnWidth, alignment: .leading)
                        .padding(.horizontal, 48).padding(.top, 72).padding(.bottom, 96)
                        .frame(maxWidth: .infinity)
                }
                .themedScrollbar()
                .id(article.entry.id)
                .environment(\.openURL, OpenURLAction { url in
                    MainActor.assumeIsolated { model.openLink(url) }
                    return .handled
                })
                actions(article.entry)
            } else {
                Text("Select an article").font(.ui(14)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.showingType) { _, showing in
            if showing {
                layer.show(at: typeFrame) { TypeMenu().floatPanel(padding: 14) }
            } else {
                layer.close()
            }
        }
        .onChange(of: layer.item == nil) { _, closed in if closed { model.showingType = false } }
    }

    private func column(_ article: Article) -> some View {
        let entry = article.entry
        let date = Date(timeIntervalSince1970: Double(entry.publishedAt ?? entry.firstSeenAt) / 1000)
        return VStack(alignment: .leading, spacing: 0) {
            Text([entry.feedTitle, Dates.long(date)].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(13)).foregroundStyle(p.muted).padding(.bottom, 20)
            Text(entry.title ?? "Untitled")
                .font(.custom(titleFamily, fixedSize: 48).weight(.semibold)).tracking(-0.72)
                .padding(.bottom, 32)
                .textSelection(.enabled)
            if let status = model.fullTextStatus {
                Text(status).font(.ui(13)).foregroundStyle(p.muted).padding(.bottom, 16)
            }
            if article.blocks.isEmpty {
                Text("This feed sent no text for this article.")
                    .font(.custom(family, fixedSize: textSize)).foregroundStyle(p.inkSoft).padding(.bottom, 16)
                HStack(spacing: 8) {
                    Button("Fetch full article") { model.fetchFull() }.buttonStyle(Plain())
                    Button("Open page") { model.openPage() }.buttonStyle(Plain())
                }
            }
            BlocksView(blocks: article.blocks, size: textSize, spacing: spacing)
        }
    }

    private func actions(_ entry: Entry) -> some View {
        HStack(spacing: 4) {
            Button { model.showingType.toggle() } label: {
                Text("Aa").font(.ui(13, .medium)).foregroundStyle(p.inkSoft)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Text and theme")
            .floatFrame($typeFrame)
            IconButton(glyph: .star, help: entry.starred ? "Remove star" : "Star", color: entry.starred ? p.unread : nil, filled: entry.starred) {
                model.toggleStar()
            }
            IconButton(glyph: .circle, help: entry.read ? "Mark unread" : "Mark read", color: entry.read ? nil : p.unread, filled: !entry.read) {
                model.toggleRead()
            }
            Button { model.openPage() } label: {
                HStack(spacing: 6) {
                    Icon(glyph: .globe)
                    Text("Open page").font(.ui(13, .medium)).foregroundStyle(p.ink)
                }
                .padding(.leading, 8).padding(.trailing, 10).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(p.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the page here. Command-click a link for your browser.")
        }
        .padding(.top, 11).padding(.trailing, 16)
    }
}

/// Renders the content model. Inline runs become one AttributedString per block, so
/// text selects across links. Nothing here can execute: blocks hold only text.
struct BlocksView: View {
    let blocks: [Block]
    let size: Double
    let spacing: Double
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
    }

    private var leading: CGFloat { max(0, size * spacing - size * 1.2) }

    private func font(_ size: Double, bold: Bool = false, italic: Bool = false, heading: Bool = false) -> Font {
        var font = Font.custom(heading ? titleFamily : family, fixedSize: size)
        if bold { font = font.weight(.semibold) }
        if italic { font = font.italic() }
        return font
    }

    private func inline(_ nodes: [Block], bold: Bool = false, italic: Bool = false, link: URL? = nil, base: Double? = nil, heading: Bool = false) -> AttributedString {
        var out = AttributedString()
        let size = base ?? self.size
        for node in nodes {
            switch node.t {
            case "text":
                var run = AttributedString(node.v ?? "")
                run.font = font(size, bold: bold, italic: italic, heading: heading)
                if let link {
                    run.link = link
                    run.foregroundColor = p.unread
                    run.underlineStyle = .single
                }
                out += run
            case "code":
                var run = AttributedString(node.v ?? "")
                run.font = .code(size * 0.85)
                out += run
            case "strong": out += inline(node.c ?? [], bold: true, italic: italic, link: link, base: size, heading: heading)
            case "em": out += inline(node.c ?? [], bold: bold, italic: true, link: link, base: size, heading: heading)
            case "link":
                let target = URL(string: node.href ?? "").flatMap { Links.isSafe($0) ? $0 : nil }
                out += inline(node.c ?? [], bold: bold, italic: italic, link: target ?? link, base: size, heading: heading)
            case "br": out += AttributedString("\n")
            default: break
            }
        }
        return out
    }

    private func paragraph(_ nodes: [Block]) -> some View {
        Text(inline(nodes))
            .lineSpacing(leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func isInline(_ node: Block) -> Bool {
        ["text", "em", "strong", "link", "br"].contains(node.t) || (node.t == "code" && node.lang == nil)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block.t {
        case "p":
            paragraph(block.c ?? []).padding(.bottom, 20)
        case "h":
            let level = block.level ?? 2
            let size = level <= 2 ? 27.0 : level == 3 ? 23.0 : 20.0
            Text(inline(block.c ?? [], bold: true, base: size, heading: true))
                .tracking(-0.27).lineSpacing(6)
                .textSelection(.enabled)
                .padding(.top, 12).padding(.bottom, 12)
        case "code":
            ScrollView(.horizontal) {
                Text(block.v ?? "").font(.code(14)).lineSpacing(5).textSelection(.enabled)
                    .padding(.vertical, 16).padding(.horizontal, 20)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 24)
        case "quote":
            HStack(spacing: 16) {
                Rectangle().fill(p.control).frame(width: 2)
                BlocksView(blocks: wrap(block.c ?? []), size: size, spacing: spacing)
                    .foregroundStyle(p.inkSoft)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 20)
        case "list":
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(block.ordered == true ? "\(index + 1)." : "•").font(font(size)).foregroundStyle(p.muted)
                        BlocksView(blocks: wrap(item), size: size, spacing: spacing)
                    }
                }
            }
            .padding(.bottom, 20)
        case "table":
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array((block.rows ?? []).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(unwrap(cell), base: size * 0.85)).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        case "hr":
            Rule().padding(.vertical, 20)
        case "img":
            ArticleImage(block: block).padding(.bottom, 20)
        case "embed":
            if let text = block.href { Link(text, destination: URL(string: text) ?? URL(string: "about:blank")!).font(.ui(14)).padding(.bottom, 20) }
        default:
            EmptyView()
        }
    }

    /// List items and quotes may hold bare inlines. Give those a paragraph.
    private func wrap(_ nodes: [Block]) -> [Block] {
        var out: [Block] = []
        var run: [Block] = []
        func flush() {
            if !run.isEmpty {
                out.append(Block(t: "p", v: nil, lang: nil, src: nil, alt: nil, href: nil, level: nil, ordered: nil, items: nil, rows: nil, c: run))
                run = []
            }
        }
        for node in nodes {
            if isInline(node) { run.append(node) } else { flush(); out.append(node) }
        }
        flush()
        return out
    }

    private func unwrap(_ nodes: [Block]) -> [Block] {
        nodes.flatMap { $0.t == "p" ? ($0.c ?? []) : [$0] }
    }
}

/// An image request tells the publisher you are reading, so loading is a choice.
struct ArticleImage: View {
    let block: Block
    @State private var loadThisOne = false
    @Environment(\.palette) private var p

    private var loadImages: Bool { Prefs.shared.ui.loadImages }
    private var url: URL? { URL(string: block.src ?? "").flatMap { Links.isSafe($0) ? $0 : nil } }

    var body: some View {
        if let url, loadImages || loadThisOne {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Rectangle().fill(p.surface).frame(height: 120)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if url != nil {
            Button { loadThisOne = true } label: {
                HStack {
                    Text((block.alt ?? "").isEmpty ? "Image" : block.alt!).lineLimit(1)
                    Spacer()
                    Text("Load").foregroundStyle(p.unread)
                }
                .font(.ui(13)).foregroundStyle(p.muted)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

/// The quick controls behind Aa: theme, reading font and size.
struct TypeMenu: View {
    @Environment(\.palette) private var p
    @Environment(\.openSettings) private var openSettings

    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 66), spacing: 8)]

    var body: some View {
        @Bindable var prefs = Prefs.shared
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(prefs.allThemes, id: \.self) { id in
                    let tile = Palette.resolved(id)
                    Button {
                        prefs.ui.theme = id
                        prefs.ui.followSystem = false
                    } label: {
                        Text("Aa")
                            .font(.custom(Fonts.resolve(prefs.fonts(of: id).reading ?? Tokens.fontReading), fixedSize: 16))
                            .foregroundStyle(tile.ink)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(tile.ground, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.id == id ? p.unread : p.hairline, lineWidth: p.id == id ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(prefs.themeName(id))
                }
            }
            HStack {
                Text("Font").font(.ui(14))
                Spacer()
                FontField(slot: \.reading)
            }
            FontChangeStrip(short: true)
            Rule()
            HStack {
                Text("Size").font(.ui(14))
                Spacer()
                Button { prefs.ui.textSize = max(14, prefs.ui.textSize - 1) } label: { Text("A").font(.ui(12)).frame(width: 12) }.buttonStyle(Plain())
                Text("\(Int(prefs.ui.textSize))").font(.ui(13)).foregroundStyle(p.muted).frame(width: 24)
                Button { prefs.ui.textSize = min(28, prefs.ui.textSize + 1) } label: { Text("A").font(.ui(16)).frame(width: 12) }.buttonStyle(Plain())
            }
            Button("More in Settings") { openSettings() }
                .buttonStyle(.plain).font(.ui(13)).foregroundStyle(p.muted)
        }
        .frame(width: 280)
    }
}

import SwiftUI

struct ReaderPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @AppStorage(Keys.columnWidth) private var columnWidth = 640.0
    @AppStorage(Keys.textSize) private var textSize = 19.0
    @AppStorage(Keys.lineSpacing) private var spacing = 1.6

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .topTrailing) {
            if let article = model.article {
                ScrollView {
                    column(article)
                        .frame(maxWidth: columnWidth, alignment: .leading)
                        .padding(.horizontal, 48).padding(.top, 72).padding(.bottom, 96)
                        .frame(maxWidth: .infinity)
                }
                .id(article.entry.id)
                .environment(\.openURL, OpenURLAction { url in
                    if Links.isSafe(url) { return .systemAction }
                    return .discarded
                })
                actions(article.entry)
            } else {
                Text("Select an article").font(.ui(14)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func column(_ article: Article) -> some View {
        let entry = article.entry
        let date = Date(timeIntervalSince1970: Double(entry.publishedAt ?? entry.firstSeenAt) / 1000)
        return VStack(alignment: .leading, spacing: 0) {
            Text([entry.feedTitle, Dates.long(date)].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(13)).foregroundStyle(p.muted).padding(.bottom, 20)
            Text(entry.title ?? "Untitled")
                .font(.custom(family, fixedSize: 48).weight(.semibold)).tracking(-0.72)
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
        @Bindable var model = model
        return HStack(spacing: 20) {
            action("Aa") { model.showingType.toggle() }
                .popover(isPresented: $model.showingType, arrowEdge: .bottom) {
                    Themed { TypeMenu() }
                }
            action(entry.starred ? "Starred" : "Star") { model.toggleStar() }
            action(entry.read ? "Mark unread" : "Mark read") { model.toggleRead() }
            action("Open page") { model.openPage() }
        }
        .padding(.top, 18).padding(.trailing, 24)
    }

    private func action(_ title: String, run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(.plain).font(.ui(13, .medium)).foregroundStyle(p.inkSoft)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
    }

    private var leading: CGFloat { max(0, size * spacing - size * 1.2) }

    private func font(_ size: Double, bold: Bool = false, italic: Bool = false) -> Font {
        var font = Font.custom(family, fixedSize: size)
        if bold { font = font.weight(.semibold) }
        if italic { font = font.italic() }
        return font
    }

    private func inline(_ nodes: [Block], bold: Bool = false, italic: Bool = false, link: URL? = nil, base: Double? = nil) -> AttributedString {
        var out = AttributedString()
        let size = base ?? self.size
        for node in nodes {
            switch node.t {
            case "text":
                var run = AttributedString(node.v ?? "")
                run.font = font(size, bold: bold, italic: italic)
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
            case "strong": out += inline(node.c ?? [], bold: true, italic: italic, link: link, base: size)
            case "em": out += inline(node.c ?? [], bold: bold, italic: true, link: link, base: size)
            case "link":
                let target = URL(string: node.href ?? "").flatMap { Links.isSafe($0) ? $0 : nil }
                out += inline(node.c ?? [], bold: bold, italic: italic, link: target ?? link, base: size)
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
            Text(inline(block.c ?? [], bold: true, base: size))
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
    @AppStorage(Keys.loadImages) private var loadImages = false
    @State private var loadThisOne = false
    @Environment(\.palette) private var p

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

struct TypeMenu: View {
    @Environment(\.palette) private var p
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Keys.theme) private var theme = "light"
    @AppStorage(Keys.followSystem) private var followSystem = true
    @AppStorage(Keys.readingFont) private var readingFont = Tokens.fontReading
    @AppStorage(Keys.textSize) private var textSize = 19.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(["light", "dark", "newsprint", "terminal"], id: \.self) { id in
                    let tile = Palette.named(id)
                    Button { theme = id; followSystem = false } label: {
                        Text("Aa")
                            .font(id == "terminal" ? .code(14) : .custom(Fonts.resolve(readingFont), fixedSize: 17))
                            .foregroundStyle(tile.ink)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(tile.ground, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.id == id ? p.unread : p.hairline, lineWidth: p.id == id ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(spacing: 0) {
                ForEach(Fonts.choices, id: \.self) { family in
                    Button { readingFont = family } label: {
                        HStack {
                            Text(Fonts.label(family)).font(.custom(Fonts.resolve(family), fixedSize: 16))
                            Spacer()
                            if readingFont == family { Text("✓").font(.ui(13)).foregroundStyle(p.unread) }
                        }
                        .padding(.horizontal, 8).frame(height: 34)
                        .background(readingFont == family ? p.selected : .clear, in: RoundedRectangle(cornerRadius: Tokens.radiusControl))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Rule()
            HStack {
                Text("Size").font(.ui(14))
                Spacer()
                Button { textSize = max(14, textSize - 1) } label: { Text("A").font(.ui(12)).frame(width: 12) }.buttonStyle(Plain())
                Text("\(Int(textSize))").font(.ui(13)).foregroundStyle(p.muted).frame(width: 24)
                Button { textSize = min(28, textSize + 1) } label: { Text("A").font(.ui(16)).frame(width: 12) }.buttonStyle(Plain())
            }
            Button("More in Settings") { openSettings() }
                .buttonStyle(.plain).font(.ui(13)).foregroundStyle(p.muted)
        }
        .padding(14)
        .frame(width: 300)
    }
}

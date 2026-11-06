import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Carries the address from the first-run field into the sheet.
@MainActor final class AddFeedDraft {
    static let shared = AddFeedDraft()
    var address = ""
}

private struct PreviewParams: Encodable, Sendable { let url: String }

private struct AddParams: Encodable, Sendable {
    let url: String
    var title: String?
    var folder: String?
}

struct AddFeedSheet: View {
    enum Phase: Equatable {
        case idle, looking
        case found([Candidate])
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var outer
    @State private var address = ""
    @State private var phase = Phase.idle
    @State private var chosen: Set<String> = []
    @State private var name = ""
    @State private var folder: Int64?
    @State private var adding = false
    @State private var lookup: Task<Void, Never>?

    var body: some View {
        Themed { form }
    }

    private var form: some View {
        SheetBody(
            address: $address, phase: phase, chosen: $chosen, name: $name, folder: $folder, adding: adding,
            folders: model.folderOutline(),
            onLookup: look, onCancel: { dismiss() }, onSubscribe: subscribe,
            onImport: { dismiss(); OPML.importFile(model) }
        )
        .frame(width: 560)
        .onChange(of: address) { _, _ in scheduleLookup() }
        .onAppear {
            folder = model.addFeedFolder
            model.addFeedFolder = nil
            address = AddFeedDraft.shared.address
            AddFeedDraft.shared.address = ""
            if address.isEmpty, let text = NSPasteboard.general.string(forType: .string), text.hasPrefix("http"), !text.contains(where: \.isWhitespace) {
                address = text
            }
        }
    }

    /// Looks up shortly after typing stops, so a paste needs no second step.
    private func scheduleLookup() {
        lookup?.cancel()
        phase = .idle
        guard address.contains(".") else { return }
        lookup = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { await run() }
        }
    }

    private func look() {
        lookup?.cancel()
        lookup = Task { await run() }
    }

    private func run() async {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phase = .looking
        do {
            let found: Items<Candidate> = try await Daemon.shared.callSlow("feeds.preview", PreviewParams(url: text))
            guard !Task.isCancelled else { return }
            if found.items.isEmpty {
                phase = .failed("The page advertises no feed, and common addresses like /feed and /rss.xml came back empty. If you know the feed address, paste it above.")
            } else {
                phase = .found(found.items)
                chosen = [found.items[0].url]
                name = found.items[0].title ?? ""
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed("That address could not be reached. \(error.localizedDescription)")
        }
    }

    private func subscribe() {
        guard case .found(let candidates) = phase else { return }
        adding = true
        Task {
            let picked = candidates.filter { chosen.contains($0.url) }
            do {
                for candidate in picked {
                    // A chosen name only makes sense when adding one feed.
                    let title = picked.count == 1 && name != candidate.title && !name.isEmpty ? name : nil
                    let added: AddResult = try await Daemon.shared.callSlow("feeds.add", AddParams(url: candidate.url, title: title))
                    if let folder { model.moveFeed(added.id, to: folder) }
                }
                await model.reload()
                dismiss()
            } catch {
                adding = false
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

private struct SheetBody: View {
    @Binding var address: String
    let phase: AddFeedSheet.Phase
    @Binding var chosen: Set<String>
    @Binding var name: String
    @Binding var folder: Int64?
    let adding: Bool
    let folders: [(folder: Folder, depth: Int)]
    let onLookup: () -> Void
    let onCancel: () -> Void
    let onSubscribe: () -> Void
    let onImport: () -> Void

    @Environment(\.palette) private var p
    @Environment(\.readingFamily) private var family
    @Environment(\.titleFamily) private var titleFamily
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a feed")
                .font(.custom(titleFamily, fixedSize: 26).weight(.semibold)).tracking(-0.26)
                .padding(.bottom, 16)
            TextField("", text: $address)
                .textFieldStyle(.plain).font(.ui(15)).focused($focused)
                .padding(.horizontal, 12).frame(height: 38)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.unread, lineWidth: 2))
                .onSubmit { if canSubscribe { onSubscribe() } else { onLookup() } }
            details
            HStack {
                Button("Import OPML", action: onImport).buttonStyle(.plain).font(.ui(13)).foregroundStyle(p.muted)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(Plain()).keyboardShortcut(.cancelAction)
                if case .failed = phase {
                    Button("Try again", action: onLookup).buttonStyle(Plain())
                } else {
                    Button(chosen.count > 1 ? "Subscribe to \(chosen.count)" : "Subscribe", action: onSubscribe)
                        .buttonStyle(Primary()).disabled(!canSubscribe).opacity(canSubscribe ? 1 : 0.4)
                }
            }
            .padding(.top, 24)
        }
        .padding(28)
        .background(p.ground)
        .onAppear { focused = true }
    }

    private var canSubscribe: Bool {
        if case .found = phase { return !chosen.isEmpty && !adding }
        return false
    }

    @ViewBuilder private var details: some View {
        switch phase {
        case .idle:
            hint("Paste a site or feed address. The feed is found for you.")
        case .looking:
            hint("Looking for a feed…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("No feed found on this site").font(.ui(14, .semibold))
                Text(message).font(.ui(13)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
        case .found(let candidates) where candidates.count == 1:
            hint("Paste a site or feed address. The feed is found for you.")
            single(candidates[0])
        case .found(let candidates):
            hint("This site has \(candidates.count) feeds. Pick the ones you want.")
            ForEach(candidates) { candidate in
                Rule()
                choice(candidate)
            }
            Rule()
            folderRow.padding(.top, 18)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.ui(13)).foregroundStyle(p.muted).padding(.top, 8).padding(.bottom, 20)
    }

    private func single(_ candidate: Candidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rule().padding(.bottom, 16)
            Text(candidate.title ?? "Untitled feed").font(.ui(16, .semibold))
            Text(candidate.url).font(.ui(13)).foregroundStyle(p.muted).padding(.bottom, 12).lineLimit(1)
            ForEach(candidate.latest, id: \.self) { title in
                Text(title).font(.custom(family, fixedSize: 17)).foregroundStyle(p.unread).lineLimit(1).padding(.vertical, 2)
            }
            VStack(spacing: 10) {
                row("Name") {
                    TextField("", text: $name).textFieldStyle(.plain).font(.ui(14))
                        .padding(.horizontal, 10).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: Radii.control).stroke(p.control))
                }
                folderRow
            }
            .padding(.top, 18)
        }
    }

    private var folderRow: some View {
        row("Folder") {
            SelectBox(
                selection: $folder,
                options: [SelectOption(value: nil, label: "None")]
                    + folders.map { SelectOption(value: $0.folder.id, label: $0.folder.name, indent: CGFloat($0.depth) * 16) },
                width: 448, height: 32)
        }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.ui(14)).foregroundStyle(p.muted).frame(width: 64, alignment: .leading)
            content()
        }
    }

    private func choice(_ candidate: Candidate) -> some View {
        let on = chosen.contains(candidate.url)
        return Button {
            if on { chosen.remove(candidate.url) } else { chosen.insert(candidate.url) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(on ? p.unread : .clear)
                    RoundedRectangle(cornerRadius: 5).stroke(on ? p.unread : p.control)
                    if on { Icon(glyph: .check, size: 13, color: p.onAccent) }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.title ?? "Untitled feed").font(.ui(14)).foregroundStyle(p.ink)
                    Text(candidate.url).font(.ui(13)).foregroundStyle(p.muted).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ImportParams: Encodable, Sendable { let path: String }
private struct ImportResult: Decodable, Sendable { let added: Int; let existing: Int }
private struct ExportResult: Decodable, Sendable { let opml: String }

@MainActor enum OPML {
    static func importFile(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let _: ImportResult = try await Daemon.shared.callSlow("opml.import", ImportParams(path: url.path))
                await model.reload()
            } catch {
                model.problem = error.localizedDescription
            }
        }
    }

    static func export(_ model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "feeds.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let result: ExportResult = try await Daemon.shared.call("opml.export")
                try result.opml.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.problem = error.localizedDescription
            }
        }
    }
}

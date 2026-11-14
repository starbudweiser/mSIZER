// mSIZER — interface du module RAW → DNG : réglages, grille de dérushage, visionneuse, conversion.
import SwiftUI
import AppKit
import ImageIO

// MARK: - Images (aperçus intégrés aux RAW, lus sans décoder le capteur)

final class BoxedImage { let cg: CGImage; init(_ c: CGImage) { cg = c } }

actor Gate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async { if running < limit { running += 1 } else { await withCheckedContinuation { waiters.append($0) } } }
    func release() { if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() } }
}

struct RawHist {
    var r = [Int](repeating: 0, count: 256), g = [Int](repeating: 0, count: 256), b = [Int](repeating: 0, count: 256)
    var shadows = 0.0, highlights = 0.0
}

enum RawImages {
    private static let thumbs: NSCache<NSURL, NSImage> = { let c = NSCache<NSURL, NSImage>(); c.countLimit = 900; return c }()
    private static let bigs: NSCache<NSURL, BoxedImage> = { let c = NSCache<NSURL, BoxedImage>(); c.countLimit = 6; return c }()
    private static let gate = Gate(limit: 4)

    nonisolated static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let f = try? RawFile(url: url) else { return nil }
        if let jpeg = f.previewJPEG(), let src = CGImageSourceCreateWithData(jpeg as CFData, nil) {
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                                              kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        return f.previewBitmap()
    }

    static func cachedThumb(_ url: URL) -> NSImage? { thumbs.object(forKey: url as NSURL) }

    static func thumb(_ url: URL) async -> NSImage? {
        if let c = thumbs.object(forKey: url as NSURL) { return c }
        await gate.acquire()
        defer { Task { await gate.release() } }
        if Task.isCancelled { return nil }
        guard let cg = decode(url, maxPixel: 300) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs.setObject(img, forKey: url as NSURL)
        return img
    }

    static func large(_ url: URL) async -> CGImage? {
        if let c = bigs.object(forKey: url as NSURL) { return c.cg }
        await gate.acquire()
        defer { Task { await gate.release() } }
        if Task.isCancelled { return nil }
        guard let cg = decode(url, maxPixel: 12000) else { return nil }
        bigs.setObject(BoxedImage(cg), forKey: url as NSURL)
        return cg
    }

    nonisolated static func histogram(_ cg: CGImage) -> RawHist {
        let w = 256, h = max(1, 256 * cg.height / max(1, cg.width))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var hist = RawHist()
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var sh = 0, hi = 0
        for i in 0..<(w * h) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            hist.r[r] += 1; hist.g[g] += 1; hist.b[b] += 1
            if min(r, g, b) <= 2 { sh += 1 }
            if max(r, g, b) >= 253 { hi += 1 }
        }
        hist.shadows = Double(sh) / Double(w * h); hist.highlights = Double(hi) / Double(w * h)
        return hist
    }
}

// MARK: - Module

struct RawModule: View {
    @ObservedObject var store = RawStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            RawSettingsPanel().frame(width: 380)
            Rectangle().fill(Socle.C.border).frame(width: 1)
            if store.items.isEmpty && !store.scanning {
                RawEmpty().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    RawToolbar()
                    Rectangle().fill(Socle.C.border).frame(height: 1)
                    if store.view == .grid { RawGrid() } else { RawLoupeArea() }
                }
            }
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onChange(of: store.currentID) { _, _ in focused = true }
        .onKeyPress(phases: [.down, .repeat]) { p in handle(p) }
    }

    private func handle(_ p: KeyPress) -> KeyPress.Result {
        if p.modifiers.contains(.command) || p.modifiers.contains(.control) { return .ignored }
        switch p.key {
        case .leftArrow: store.move(-1); return .handled
        case .rightArrow: store.move(1); return .handled
        case .upArrow: store.move(store.view == .grid ? -store.columns : -1); return .handled
        case .downArrow: store.move(store.view == .grid ? store.columns : 1); return .handled
        case .space: store.zoom100.toggle(); if store.view == .grid, let c = store.currentID { store.open(c) }; return .handled
        case .return: if let c = store.currentID { store.open(c) }; return .handled
        case .escape: if store.view == .loupe { store.view = .grid; return .handled }; return .ignored
        default: break
        }
        switch p.characters.lowercased() {
        case "0", "1", "2", "3", "4", "5": store.setRating(Int(p.characters)!); return .handled
        case "p": store.setFlag(.pick); return .handled
        case "x": store.setFlag(.reject); return .handled
        case "u": store.setFlag(.none); store.setRating(0); return .handled
        case "g": store.view = .grid; return .handled
        case "e": if store.currentID != nil { store.view = .loupe }; return .handled
        case "i": store.showInfo.toggle(); return .handled
        default: return .ignored
        }
    }
}

struct RawEmpty: View {
    @ObservedObject var store = RawStore.shared
    var body: some View {
        VStack(spacing: Socle.M.space4) {
            MsizerMark().frame(width: 96, height: 96).foregroundStyle(Brand.color)
            Text(L.t("raw.empty.title")).socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
            Text(L.t("raw.empty.body")).socle(Socle.T.reading).foregroundStyle(Socle.C.textMuted).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button(L.t("raw.add")) { store.pickFiles() }.buttonStyle(SocleButtonStyle(.action)).frame(width: 220)
        }
        .padding(Socle.M.space8).frame(maxWidth: 560).padding(Socle.M.space6)
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusLg).stroke(Socle.C.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [6, 4])).padding(28))
    }
}

// MARK: - Réglages

struct RawSettingsPanel: View {
    @ObservedObject var store = RawStore.shared

    var body: some View {
        let s = $store.settings
        ScrollView {
            VStack(spacing: Socle.M.space2) {
                OpCard(title: L.t("raw.op.dng"), isOn: nil) {
                    Check(title: L.t("raw.dng.compress"), help: L.t("raw.dng.compress.help"), isOn: s.compressed)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t("raw.dng.preview")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                        ChoiceGrid(options: [0, 1024, 1600, 2560], selection: s.previewMax, label: { $0 == 0 ? L.t("raw.dng.preview.none") : "\($0) px" }, minWidth: 64)
                    }
                    Check(title: L.t("raw.dng.rating"), help: L.t("raw.dng.rating.help"), isOn: s.embedRating)
                    Check(title: L.t("raw.dng.verify"), help: L.t("raw.dng.verify.help"), isOn: s.verify)
                    Hint(L.t("raw.dng.copy"))
                }
                OpCard(title: L.t("raw.op.dest"), isOn: nil) {
                    ChoiceGrid(options: RawDest.allCases, selection: s.dest, label: { L.t("raw.dest." + $0.rawValue) }, minWidth: 110)
                    switch store.settings.dest {
                    case .subfolder: Hint(L.t("raw.dest.subfolder.help"))
                    case .beside: EmptyView()
                    case .folder:
                        HStack(spacing: Socle.M.space2) {
                            Text(store.settings.folder).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                            Button(L.t("btn.choose")) { Store.shared.pickFolder(start: store.settings.folder) { store.settings.folder = $0 } }
                                .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                        }
                    }
                    Text(L.t("raw.conflict")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                    ChoiceGrid(options: RawConflict.allCases, selection: s.conflict, label: { L.t("raw.conflict." + $0.rawValue) }, minWidth: 90)
                }
                OpCard(title: L.t("raw.op.scope"), isOn: nil) {
                    ChoiceGrid(options: RawScope.allCases, selection: s.scope, label: { L.t("raw.scope." + $0.rawValue) }, minWidth: 110)
                    Text(L.t(store.scopeItems.count == 1 ? "raw.count.one" : "raw.count.many", store.scopeItems.count)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.accentText)
                }
                OpCard(title: L.t("raw.view.loupe"), isOn: nil) {
                    Check(title: L.t("raw.autoadv"), isOn: s.autoAdvance)
                    Button(L.t("raw.trash")) { askTrash() }.buttonStyle(SocleButtonStyle(.secondary)).disabled(store.rejectedCount == 0 || store.converting)
                    Hint(L.t("raw.keys"))
                }
                Hint(L.t("raw.credit")).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
            .padding(Socle.M.space3)
        }
        .background(Socle.C.bg)
    }

    private func askTrash() {
        let a = NSAlert()
        a.messageText = L.t("raw.trash.title", store.rejectedCount)
        a.informativeText = L.t("raw.trash.body")
        a.addButton(withTitle: L.t("raw.trash.ok")); a.addButton(withTitle: L.t("btn.cancel"))
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { store.trashRejected() }
    }
}

// MARK: - Barre d'outils

struct StarsView: View {
    let rating: Int
    var size: CGFloat = 10
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in Image(systemName: i <= rating ? "star.fill" : "star").font(.system(size: size)).foregroundStyle(i <= rating ? Socle.C.action : Socle.C.textDisabled) }
        }
    }
}

struct RawToolbar: View {
    @ObservedObject var store = RawStore.shared

    var body: some View {
        HStack(spacing: Socle.M.space3) {
            SocleSegmented(options: [RawView.grid, .loupe], selection: store.view, label: { L.t("raw.view." + $0.rawValue) }, tone: { _ in .strong }) { v in
                if v == .loupe, store.currentID == nil { return }
                store.view = v
            }
            SocleSegmented(options: [RawFilter.all, .picks, .unflagged, .rejects], selection: simple(store.filter),
                           label: { "\(L.t(key($0))) \(store.count($0))" }, tone: { _ in .soft }) { store.filter = $0 }
            Menu {
                ForEach(1...5, id: \.self) { n in Button(L.t("raw.filter.stars", n)) { store.filter = .stars(n) } }
            } label: {
                Text({ if case .stars(let n) = store.filter { return L.t("raw.filter.stars", n) }; return "★" }()).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                    .padding(.horizontal, Socle.M.space2).frame(minHeight: 30)
                    .background(Socle.C.control, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer(minLength: Socle.M.space2)
            ratingBar
            Rectangle().fill(Socle.C.border).frame(width: 1, height: 20)
            Menu {
                ForEach(RawSort.allCases, id: \.self) { s in Button(L.t("raw.sort." + s.rawValue)) { store.sort = s } }
            } label: {
                Text(L.t("raw.sort." + store.sort.rawValue)).socle(Socle.T.label).foregroundStyle(Socle.C.textStrong)
                    .padding(.horizontal, Socle.M.space2).frame(minHeight: 30)
                    .background(Socle.C.control, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Button(L.t("raw.add")) { store.pickFiles() }.buttonStyle(SocleButtonStyle(.secondary, height: 30)).fixedSize()
            Button(L.t("raw.clear")) { store.clear() }.buttonStyle(SocleButtonStyle(.tertiary, height: 30)).fixedSize().disabled(store.converting)
        }
        .padding(.horizontal, Socle.M.space3).frame(height: 48)
        .background(Socle.C.surfaceRaised)
    }

    private func simple(_ f: RawFilter) -> RawFilter { if case .stars = f { return .all }; return f }
    private func key(_ f: RawFilter) -> String {
        switch f { case .all: return "raw.filter.all"; case .picks: return "raw.filter.picks"; case .unflagged: return "raw.filter.unflagged"; case .rejects: return "raw.filter.rejects"; case .stars: return "raw.filter.all" }
    }

    private var ratingBar: some View {
        let cur = store.current
        return HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Button { store.setRating(cur?.rating == i ? 0 : i) } label: {
                    Image(systemName: i <= (cur?.rating ?? 0) ? "star.fill" : "star").font(.system(size: 13))
                        .foregroundStyle(i <= (cur?.rating ?? 0) ? Socle.C.action : Socle.C.textMuted)
                }.buttonStyle(.plain).help("\(i)")
            }
            Button { store.setFlag(.pick) } label: {
                Image(systemName: cur?.flag == .pick ? "flag.fill" : "flag").font(.system(size: 13)).foregroundStyle(cur?.flag == .pick ? Socle.C.success : Socle.C.textMuted)
            }.buttonStyle(.plain).help(L.t("raw.flag.pick") + " (P)").padding(.leading, 6)
            Button { store.setFlag(.reject) } label: {
                Image(systemName: "xmark.circle" + (cur?.flag == .reject ? ".fill" : "")).font(.system(size: 14)).foregroundStyle(cur?.flag == .reject ? Socle.C.danger : Socle.C.textMuted)
            }.buttonStyle(.plain).help(L.t("raw.flag.reject") + " (X)").padding(.leading, 4)
        }
        .padding(.horizontal, Socle.M.space2).frame(minHeight: 30)
        .background(Socle.C.control, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .opacity(cur == nil ? 0.5 : 1)
    }
}

// MARK: - Grille

struct RawThumb: View {
    let id: UUID
    var height: CGFloat = 130
    @ObservedObject var store = RawStore.shared
    @State private var img: NSImage?

    var body: some View {
        if let it = store.item(id) {
            let selected = store.selection.contains(id)
            ZStack(alignment: .bottom) {
                Socle.C.bgSunken
                if let img { Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if it.readable { ProgressView().controlSize(.small) }
                else { Image(systemName: "exclamationmark.triangle").foregroundStyle(Socle.C.warning) }
                VStack {
                    HStack {
                        if it.flag == .pick { Image(systemName: "flag.fill").foregroundStyle(Socle.C.success) }
                        if it.flag == .reject { Image(systemName: "xmark.circle.fill").foregroundStyle(Socle.C.danger) }
                        Spacer()
                        stateBadge(it.state)
                    }.font(.system(size: 13, weight: .bold)).shadow(color: .black.opacity(0.7), radius: 2)
                    Spacer()
                    if it.rating > 0 { StarsView(rating: it.rating).shadow(color: .black.opacity(0.7), radius: 2).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(5)
            }
            .frame(height: height)
            .opacity(it.flag == .reject ? 0.4 : 1)
            .clipShape(RoundedRectangle(cornerRadius: Socle.M.radius))
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(selected ? Socle.C.accent : Socle.C.border, lineWidth: selected ? 2 : 1))
            .task(id: id) { img = RawImages.cachedThumb(it.url); if img == nil { img = await RawImages.thumb(it.url) } }
        }
    }

    @ViewBuilder private func stateBadge(_ s: RawItem.State) -> some View {
        switch s {
        case .pending: EmptyView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Socle.C.success)
        case .skipped: Image(systemName: "arrow.uturn.right.circle.fill").foregroundStyle(Socle.C.warning)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Socle.C.danger)
        }
    }
}

struct RawGrid: View {
    @ObservedObject var store = RawStore.shared
    private let cell: CGFloat = 168

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if store.visibleIDs.isEmpty {
                        Text(L.t("raw.nomatch")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).frame(maxWidth: .infinity).padding(Socle.M.space8)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cell), spacing: 8)], spacing: 8) {
                        ForEach(store.visibleIDs, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 3) {
                                RawThumb(id: id)
                                Text(store.item(id)?.name ?? "").socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted).lineLimit(1).truncationMode(.middle)
                            }
                            .id(id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { store.open(id) }
                            .onTapGesture { store.click(id, command: NSEvent.modifierFlags.contains(.command), shift: NSEvent.modifierFlags.contains(.shift)) }
                            .contextMenu { RawMenu(id: id) }
                        }
                    }
                    .padding(Socle.M.space3)
                }
                .onChange(of: store.currentID) { _, c in if let c { proxy.scrollTo(c) } }
            }
            .onChange(of: geo.size.width) { _, w in store.columns = max(1, Int((w - 24) / (cell + 8))) }
            .onAppear { store.columns = max(1, Int((geo.size.width - 24) / (cell + 8))) }
        }
        .background(Socle.C.bg)
    }
}

struct RawMenu: View {
    let id: UUID
    @ObservedObject var store = RawStore.shared
    var body: some View {
        Button(L.t("raw.view.loupe")) { store.open(id) }
        Divider()
        ForEach(1...5, id: \.self) { n in Button("★ \(n)") { store.currentID = id; if !store.selection.contains(id) { store.selection = [id] }; store.setRating(n) } }
        Button(L.t("raw.flag.pick")) { store.currentID = id; if !store.selection.contains(id) { store.selection = [id] }; store.setFlag(.pick) }
        Button(L.t("raw.flag.reject")) { store.currentID = id; if !store.selection.contains(id) { store.selection = [id] }; store.setFlag(.reject) }
        Divider()
        if let it = store.item(id) { Button(L.t("btn.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([it.url]) } }
    }
}

// MARK: - Visionneuse

struct RawLoupeArea: View {
    @ObservedObject var store = RawStore.shared
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RawLoupe()
                Rectangle().fill(Socle.C.border).frame(height: 1)
                RawFilmstrip()
            }
            if store.showInfo {
                Rectangle().fill(Socle.C.border).frame(width: 1)
                RawInfo().frame(width: 270)
            }
        }
    }
}

struct RawLoupe: View {
    @ObservedObject var store = RawStore.shared
    @State private var image: CGImage?
    @State private var loading = false
    @State private var missing = false

    var body: some View {
        ZStack {
            Socle.C.bgSunken
            if let image {
                if store.zoom100 {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: NSScreen.main?.backingScaleFactor ?? 2).interpolation(.high)
                    }
                } else {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit().padding(Socle.M.space3)
                }
            } else if missing {
                Text(L.t("raw.nopreview")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            }
            if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(Socle.M.space3) }
            if let it = store.current {
                VStack {
                    HStack(spacing: Socle.M.space2) {
                        Text(it.name).socle(Socle.T.mono).foregroundStyle(.white)
                        if it.rating > 0 { StarsView(rating: it.rating, size: 12) }
                        if it.flag == .pick { Image(systemName: "flag.fill").foregroundStyle(Socle.C.success) }
                        if it.flag == .reject { Image(systemName: "xmark.circle.fill").foregroundStyle(Socle.C.danger) }
                        Spacer()
                    }
                    .shadow(color: .black.opacity(0.8), radius: 3).padding(Socle.M.space3)
                    Spacer()
                }.allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.zoom100.toggle() }
        .task(id: store.currentID) { await load() }
    }

    private func load() async {
        guard let it = store.current else { image = nil; return }
        loading = true; missing = false
        let cg = await RawImages.large(it.url)
        if Task.isCancelled { return }
        image = cg; missing = cg == nil; loading = false
        // Voisines préchargées : la navigation aux flèches reste instantanée.
        if let i = store.visibleIDs.firstIndex(of: it.id) {
            for k in [i + 1, i - 1, i + 2] where k >= 0 && k < store.visibleIDs.count {
                if let n = store.item(store.visibleIDs[k]) { Task.detached(priority: .utility) { _ = await RawImages.large(n.url) } }
            }
        }
    }
}

struct RawFilmstrip: View {
    @ObservedObject var store = RawStore.shared
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(store.visibleIDs, id: \.self) { id in
                        RawThumb(id: id, height: 78).frame(width: 104).id(id)
                            .onTapGesture { store.click(id, command: false, shift: false) }
                    }
                }.padding(Socle.M.space2)
            }
            .onChange(of: store.currentID) { _, c in if let c { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(c, anchor: .center) } } }
            .onAppear { if let c = store.currentID { proxy.scrollTo(c, anchor: .center) } }
        }
        .frame(height: 100).background(Socle.C.surfaceRaised)
    }
}

struct RawInfo: View {
    @ObservedObject var store = RawStore.shared
    @State private var hist: RawHist?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                if let it = store.current {
                    Text(L.t("raw.histo")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                    HistogramView(hist: hist).frame(height: 90)
                    if let h = hist {
                        HStack {
                            Text("\(L.t("raw.clip.shadows")) \(pct(h.shadows))").foregroundStyle(h.shadows > 0.02 ? Socle.C.warning : Socle.C.textSubtle)
                            Spacer()
                        }.socle(Socle.T.meta)
                        Text("\(L.t("raw.clip.highlights")) \(pct(h.highlights))").socle(Socle.T.meta).foregroundStyle(h.highlights > 0.02 ? Socle.C.warning : Socle.C.textSubtle)
                    }
                    Rectangle().fill(Socle.C.border).frame(height: 1)
                    Text(L.t("raw.info.title")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                    row("raw.info.file", it.name)
                    row("raw.info.camera", it.meta.camera)
                    row("raw.info.lens", it.meta.lens)
                    row("raw.info.iso", it.meta.iso > 0 ? "\(Int(it.meta.iso))" : "")
                    row("raw.info.shutter", it.meta.shutterText)
                    row("raw.info.aperture", it.meta.aperture > 0 ? String(format: "f/%.1f", it.meta.aperture) : "")
                    row("raw.info.focal", it.meta.focal > 0 ? String(format: "%.0f mm", it.meta.focal) : "")
                    row("raw.info.date", it.meta.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    row("raw.info.size", it.meta.width > 0 ? "\(it.meta.displayW) × \(it.meta.displayH) · \(Format.bytes(Int(it.bytes)))" : Format.bytes(Int(it.bytes)))
                    switch it.state {
                    case .done(let b): Text("✓ \(L.t("raw.status.done")) · \(Format.bytes(b))").socle(Socle.T.meta).foregroundStyle(Socle.C.success)
                    case .skipped(let m): Text(m).socle(Socle.T.meta).foregroundStyle(Socle.C.warning)
                    case .failed(let e): Text("✕ \(e)").socle(Socle.T.meta).foregroundStyle(Socle.C.danger)
                    case .pending: EmptyView()
                    }
                }
            }
            .padding(Socle.M.space3).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Socle.C.surface)
        .task(id: store.currentID) {
            hist = nil
            guard let it = store.current, let cg = await RawImages.large(it.url) else { return }
            let h = await Task.detached(priority: .utility) { RawImages.histogram(cg) }.value
            if !Task.isCancelled { hist = h }
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%.1f %%", v * 100) }

    @ViewBuilder private func row(_ key: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(L.t(key)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                Text(value).socle(Socle.T.mono).foregroundStyle(Socle.C.text).lineLimit(2).textSelection(.enabled)
            }
        }
    }
}

struct HistogramView: View {
    let hist: RawHist?
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Socle.C.bgSunken))
            guard let h = hist else { return }
            let peak = Double(max(1, (1...254).map { max(h.r[$0], h.g[$0], h.b[$0]) }.max() ?? 1))
            for (bins, color) in [(h.r, Color.red), (h.g, Color.green), (h.b, Color.blue)] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<256 {
                    let v = min(1, Double(bins[i]) / peak)
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath()
                var c = ctx; c.blendMode = .plusLighter
                c.fill(p, with: .color(color.opacity(0.55)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border, lineWidth: 1))
    }
}

// MARK: - Barre du bas

struct RawBottomBar: View {
    @ObservedObject var store = RawStore.shared
    var body: some View {
        HStack(spacing: Socle.M.space4) {
            if store.converting {
                ProgressBar(value: store.progress).frame(maxWidth: .infinity)
                Text("\(Int(store.progress * 100)) %").socle(Socle.T.mono).foregroundStyle(Socle.C.accentText)
                Button(L.t("btn.cancel")) { store.cancel() }.buttonStyle(SocleButtonStyle(.secondary)).frame(width: 160)
            } else {
                Text(store.scanning ? L.t("raw.loading") : (store.summary ?? "")).socle(Socle.T.body)
                    .foregroundStyle(store.summary == nil ? Socle.C.textMuted : (store.summaryWarning ? Socle.C.warning : Socle.C.success))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let f = store.lastOutput {
                    Button(L.t("btn.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([f]) }.buttonStyle(SocleButtonStyle(.secondary)).frame(width: 200)
                }
                let n = store.scopeItems.count
                Button(L.t("raw.btn.convert.n", n)) { store.convert() }.buttonStyle(SocleButtonStyle(.action)).frame(width: 280).disabled(n == 0)
            }
        }
        .padding(.horizontal, Socle.M.space4).frame(height: 64)
        .background(Socle.C.surfaceRaised)
    }
}

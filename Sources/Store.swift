// mSIZER — état de l'appli : liste de photos, réglages, préréglages, lot en cours, aperçu.
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var items: [PhotoItem] = []
    @Published var selection: UUID? { didSet { schedulePreview() } }
    @Published var settings: Settings { didSet {
        guard settings != oldValue else { return }
        // Recadrage manuel activé : l'onglet « Avant » porte les poignées.
        if settings.cropOn, settings.cropRatio == .manual, !(oldValue.cropOn && oldValue.cropRatio == .manual) { showAfter = false }
        persist(); schedulePreview()
    } }
    @Published var showAfter = true
    @Published var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "") ?? .photos { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appMode") } }
    @Published var presets: [Preset] = []
    @Published var processing = false
    @Published var progress = 0.0
    @Published var summary: String?
    @Published var summaryWarning = false
    @Published var lastOutput: URL?
    @Published var showSettings = false
    @Published var previewAfter: NSImage?
    @Published var previewBefore: NSImage?
    @Published var previewInfo = ""
    @Published var previewBusy = false

    private var batch: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    private static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mSIZER", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "settings"), let s = Settings.decodeLenient(d) { settings = s } else { settings = Settings() }
        if let d = try? Data(contentsOf: Self.supportDir.appendingPathComponent("presets.json")),
           let p = try? JSONDecoder().decode([Preset].self, from: d) { presets = p }
        // Premier lancement : le dossier de sortie, s'il est demandé, commence dans Images.
        if settings.outputFolder.isEmpty { settings.outputFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].path }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    // MARK: Préréglages

    struct BuiltIn: Identifiable { let id: String; let settings: Settings
        var name: String { L.t("preset." + id) } }

    static let builtIns: [BuiltIn] = {
        var web = Settings(); web.resizeValue = 1920; web.quality = 0.8
        var mail = Settings(); mail.resizeValue = 1280; mail.quality = 0.8; mail.maxKB = 300; mail.metaMode = .stripAll
        var insta = Settings(); insta.cropOn = true; insta.cropRatio = .r45; insta.resizeMode = .width; insta.resizeValue = 1080; insta.quality = 0.88
        var square = Settings(); square.cropOn = true; square.cropRatio = .square; square.resizeMode = .width; square.resizeValue = 1080; square.quality = 0.88
        var webp = Settings(); webp.resizeValue = 1920; webp.format = .webp; webp.quality = 0.8
        var heic = Settings(); heic.resizeOn = false; heic.format = .heic; heic.quality = 0.7
        var thumbs = Settings(); thumbs.resizeValue = 400; thumbs.quality = 0.75; thumbs.metaMode = .stripAll
        var privacy = Settings(); privacy.resizeOn = false; privacy.metaMode = .stripAll; privacy.quality = 0.95
        return [BuiltIn(id: "web", settings: web), BuiltIn(id: "mail", settings: mail), BuiltIn(id: "insta", settings: insta),
                BuiltIn(id: "square", settings: square), BuiltIn(id: "webp", settings: webp), BuiltIn(id: "heic", settings: heic), BuiltIn(id: "thumbs", settings: thumbs),
                BuiltIn(id: "privacy", settings: privacy)]
    }()

    func apply(_ s: Settings) { settings = settings.applying(preset: s) }

    func savePreset(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.name == n }) { presets[i].settings = settings } else { presets.append(Preset(name: n, settings: settings)) }
        writePresets()
    }

    func deletePreset(_ p: Preset) { presets.removeAll { $0.id == p.id }; writePresets() }

    private func writePresets() {
        try? JSONEncoder().encode(presets).write(to: Self.supportDir.appendingPathComponent("presets.json"), options: .atomic)
    }

    // MARK: Liste

    /// Dépôt de fichiers : les RAW vont au module RAW → DNG, le reste aux photos.
    static func route(_ urls: [URL]) {
        if shared.mode == .raw || (!urls.isEmpty && urls.allSatisfy { RawEngine.isRaw($0) }) { shared.mode = .raw; RawStore.shared.add(urls) }
        else { shared.add(urls) }
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url.path))
        Task.detached(priority: .userInitiated) {
            var found: [URL] = []
            for u in urls { found += Self.images(in: u) }
            let fresh = found.filter { !known.contains($0.path) }
            // Informations et vignettes lues en parallèle ; l'ordre de la liste est conservé.
            let loaded = await withTaskGroup(of: (Int, PhotoItem).self) { group -> [PhotoItem] in
                var out = [PhotoItem?](repeating: nil, count: fresh.count)
                var next = 0
                func feed() { if next < fresh.count { let i = next; next += 1; group.addTask { (i, Self.info(fresh[i])) } } }
                for _ in 0..<Engine.workers { feed() }
                while let (i, it) = await group.next() { out[i] = it; feed() }
                return out.compactMap { $0 }
            }
            await MainActor.run {
                let s = Store.shared
                var seen = Set(s.items.map(\.url.path))
                s.items += loaded.filter { seen.insert($0.url.path).inserted }
                if s.selection == nil { s.selection = s.items.first?.id }
                s.summary = nil
            }
        }
    }

    nonisolated static func images(in url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return isImage(url) ? [url] : [] }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where isImage(u) { out.append(u) }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated static func isImage(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .svg) && !t.conforms(to: .pdf)
    }

    nonisolated static func info(_ url: URL) -> PhotoItem {
        var it = PhotoItem(url: url)
        it.bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return it }
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        var w = p[kCGImagePropertyPixelWidth as String] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        if (p[kCGImagePropertyOrientation as String] as? Int ?? 1) >= 5 { swap(&w, &h) }
        it.width = w; it.height = h
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 160]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            it.thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return it
    }

    func remove(_ id: UUID) {
        guard !processing else { return }
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
    }

    func clear() { guard !processing else { return }; items = []; selection = nil; summary = nil }

    var selectedItem: PhotoItem? { items.first { $0.id == selection } }

    // MARK: Recadrage manuel

    /// Cadrage de la photo choisie : le sien, sinon celui par défaut des réglages.
    var currentCrop: NormRect { selectedItem?.cropRect ?? settings.cropRect }

    func setCrop(_ r: NormRect) {
        guard let i = items.firstIndex(where: { $0.id == selection }) else { return }
        items[i].cropRect = r
        schedulePreview()
    }

    /// Reprend le cadrage de la photo choisie pour toutes les autres.
    func applyCropToAll() {
        let r = currentCrop
        settings.cropRect = r
        for i in items.indices { items[i].cropRect = nil }
        schedulePreview()
    }

    func resetCrop() { setCrop(NormRect()) }

    /// Remet le cadrage dans le rapport verrouillé quand le verrou change.
    func relockCrop() {
        guard let r = settings.lockRatio, let it = selectedItem, it.width > 0, it.height > 0 else { return }
        let rotated = settings.rotateOn && (settings.rotation == .cw || settings.rotation == .ccw)
        let aspect = rotated ? Double(it.height) / Double(it.width) : Double(it.width) / Double(it.height)
        setCrop(currentCrop.fitted(to: r, aspect: aspect))
    }

    /// Réglages à appliquer à une photo : les siens pour le cadrage.
    func settings(for it: PhotoItem) -> Settings {
        var s = settings
        if let r = it.cropRect { s.cropRect = r }
        return s
    }

    // MARK: Lot

    func start() {
        guard !processing, !items.isEmpty else { return }
        if settings.outputMode == .folder, settings.outputFolder.isEmpty { summary = L.t("err.nofolder"); return }
        processing = true; progress = 0; summary = nil; summaryWarning = false; lastOutput = nil
        let totalIn = items.reduce(0) { $0 + $1.bytes }
        for i in items.indices { items[i].status = .pending }
        let s = settings
        let jobs = items.enumerated().map { ($0.offset, $0.element.id, $0.element.url, $0.element.cropRect) }
        let t0 = Date()
        batch = Task.detached(priority: .userInitiated) {
            let prep = Engine.prepare(s)
            let tally = Tally()
            await withTaskGroup(of: (UUID, JobResult).self) { group in
                var next = 0
                func feed() {
                    guard next < jobs.count, !Task.isCancelled else { return }
                    let (i, id, url, crop) = jobs[next]; next += 1
                    var sj = s
                    if let crop { sj.cropRect = crop }
                    group.addTask { (id, Engine.process(url, index: i, sj, prep)) }
                }
                for _ in 0..<Engine.workers { feed() }
                while let (id, r) = await group.next() {
                    tally.done += 1
                    if r.error != nil { tally.failed += 1 } else { tally.bytesOut += r.bytesOut; if tally.firstOut == nil { tally.firstOut = r.url } }
                    let frac = Double(tally.done) / Double(jobs.count)
                    await MainActor.run {
                        let st = Store.shared
                        if let k = st.items.firstIndex(where: { $0.id == id }) {
                            st.items[k].status = r.error.map { .failed($0) } ?? .done(bytes: r.bytesOut)
                        }
                        st.progress = frac
                    }
                    feed()
                }
            }
            let (done, failed, bytesOut, firstOut) = (tally.done, tally.failed, tally.bytesOut, tally.firstOut)
            let cancelled = Task.isCancelled
            await MainActor.run {
                let st = Store.shared
                st.processing = false
                let secs = Date().timeIntervalSince(t0)
                if cancelled { st.summary = L.t("sum.cancelled", done); st.summaryWarning = true }
                else {
                    var m = L.t("sum.done", done - failed, String(format: "%.1f", secs))
                    if bytesOut > 0 { m += " · " + Format.bytes(totalIn) + " → " + Format.bytes(bytesOut) }
                    if failed > 0 { m += " · " + L.t("sum.failed", failed); st.summaryWarning = true }
                    st.summary = m
                    st.lastOutput = firstOut
                }
            }
        }
    }

    func cancel() { batch?.cancel() }

    // MARK: Aperçu

    private func schedulePreview() {
        previewTask?.cancel()
        guard let it = selectedItem else { previewAfter = nil; previewBefore = nil; previewInfo = ""; return }
        let s = settings(for: it), url = it.url, id = it.id
        previewBusy = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let res: (NSImage?, NSImage?, String) = await Task.detached(priority: .userInitiated) {
                let prep = Engine.prepare(s)
                guard let r = try? Engine.render(url, s, prep, previewMax: 1400),
                      let cg = Engine.context.createCGImage(r.image, from: r.image.extent, format: .RGBA8, colorSpace: r.colorSpace) else { return (nil, nil, "") }
                let after = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                var before: NSImage?
                if s.cropOn, s.cropRatio == .manual, s.rotateOn, s.rotation != .none || s.flipH || s.flipV {
                    // Les poignées de recadrage se règlent sur l'image déjà tournée.
                    var rs = Settings(); rs.resizeOn = false; rs.rotateOn = true; rs.rotation = s.rotation; rs.flipH = s.flipH; rs.flipV = s.flipV
                    if let rr = try? Engine.render(url, rs, Engine.prepare(rs), previewMax: 1400),
                       let b = Engine.context.createCGImage(rr.image, from: rr.image.extent, format: .RGBA8, colorSpace: rr.colorSpace) {
                        before = NSImage(cgImage: b, size: NSSize(width: b.width, height: b.height))
                    }
                }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 1400]
                if before == nil, let src = CGImageSourceCreateWithURL(url as CFURL, nil), let b = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    before = NSImage(cgImage: b, size: NSSize(width: b.width, height: b.height))
                }
                let full = Engine.plan(width: Self.dims(url).0, height: Self.dims(url).1, s)
                return (before, after, "\(full.outW) × \(full.outH)")
            }.value
            if Task.isCancelled { return }
            guard let self, self.selection == id else { return }
            self.previewBefore = res.0; self.previewAfter = res.1; self.previewInfo = res.2; self.previewBusy = false
        }
    }

    nonisolated static func dims(_ url: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return (1, 1) }
        var w = p[kCGImagePropertyPixelWidth as String] as? Int ?? 1, h = p[kCGImagePropertyPixelHeight as String] as? Int ?? 1
        if (p[kCGImagePropertyOrientation as String] as? Int ?? 1) >= 5 { swap(&w, &h) }
        return (w, h)
    }
}

/// Compteurs du lot, modifiés uniquement par la boucle de collecte (un seul fil à la fois).
private final class Tally: @unchecked Sendable {
    var done = 0, failed = 0, bytesOut = 0
    var firstOut: URL?
}

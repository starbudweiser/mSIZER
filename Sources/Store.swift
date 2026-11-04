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
    @Published var settings: Settings { didSet { if settings != oldValue { persist(); schedulePreview() } } }
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
        var heic = Settings(); heic.resizeOn = false; heic.format = .heic; heic.quality = 0.7
        var thumbs = Settings(); thumbs.resizeValue = 400; thumbs.quality = 0.75; thumbs.metaMode = .stripAll
        var privacy = Settings(); privacy.resizeOn = false; privacy.metaMode = .stripAll; privacy.quality = 0.95
        return [BuiltIn(id: "web", settings: web), BuiltIn(id: "mail", settings: mail), BuiltIn(id: "insta", settings: insta),
                BuiltIn(id: "square", settings: square), BuiltIn(id: "heic", settings: heic), BuiltIn(id: "thumbs", settings: thumbs),
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

    // MARK: Lot

    func start() {
        guard !processing, !items.isEmpty else { return }
        if settings.outputMode == .folder, settings.outputFolder.isEmpty { summary = L.t("err.nofolder"); return }
        processing = true; progress = 0; summary = nil; summaryWarning = false; lastOutput = nil
        let totalIn = items.reduce(0) { $0 + $1.bytes }
        for i in items.indices { items[i].status = .pending }
        let s = settings
        let jobs = items.enumerated().map { ($0.offset, $0.element.id, $0.element.url) }
        let t0 = Date()
        batch = Task.detached(priority: .userInitiated) {
            let prep = Engine.prepare(s)
            let tally = Tally()
            await withTaskGroup(of: (UUID, JobResult).self) { group in
                var next = 0
                func feed() {
                    guard next < jobs.count, !Task.isCancelled else { return }
                    let (i, id, url) = jobs[next]; next += 1
                    group.addTask { (id, Engine.process(url, index: i, s, prep)) }
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
        let s = settings, url = it.url, id = it.id
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
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 1400]
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let b = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
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

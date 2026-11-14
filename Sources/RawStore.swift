// mSIZER — état du module RAW → DNG : liste, notation (dérushage), filtres, conversion en lot.
import Foundation
import AppKit
import ImageIO

enum AppMode: String, CaseIterable { case photos, raw }
enum RawView: String { case grid, loupe }
enum RawFilter: Hashable { case all, picks, unflagged, rejects, stars(Int) }
enum RawSort: String, CaseIterable { case name, date, rating }
enum RawScope: String, CaseIterable, Codable { case kept, picks, visible, selection }
enum RawDest: String, CaseIterable, Codable { case subfolder, beside, folder }
enum RawConflict: String, CaseIterable, Codable { case number, skip, overwrite }
enum RawFlag: Int, Codable { case none = 0, pick = 1, reject = 2 }

struct RawSettings: Codable, Equatable {
    var compressed = true
    var previewMax = 1600
    var verify = false
    var embedRating = true
    var dest: RawDest = .subfolder
    var folder = ""
    var conflict: RawConflict = .number
    var scope: RawScope = .kept
    var autoAdvance = true
}

struct RawItem: Identifiable, Equatable {
    enum State: Equatable { case pending, done(Int), skipped(String), failed(String) }
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var bytes: Int64 = 0
    var meta = RawMeta()
    var modified = Date.distantPast
    var rating = 0
    var flag: RawFlag = .none
    var state: State = .pending
    var readable = true
    var sortDate: Date { meta.date ?? modified }
}

@MainActor
final class RawStore: ObservableObject {
    static let shared = RawStore()

    @Published private(set) var items: [RawItem] = []
    @Published private(set) var visibleIDs: [UUID] = []
    @Published var settings: RawSettings { didSet { if settings != oldValue { persist() } } }
    @Published var selection: Set<UUID> = []
    @Published var currentID: UUID?
    @Published var view: RawView = .grid
    @Published var filter: RawFilter = .all { didSet { refresh() } }
    @Published var sort: RawSort = .name { didSet { refresh() } }
    @Published var zoom100 = false
    @Published var showInfo = true
    @Published var scanning = false
    @Published var converting = false
    @Published var progress = 0.0
    @Published var summary: String?
    @Published var summaryWarning = false
    @Published var lastOutput: URL?
    var columns = 4

    private var index: [UUID: Int] = [:]
    private var marks: [String: Mark]
    private var saveTask: Task<Void, Never>?
    private var batch: Task<Void, Never>?
    private var anchor: UUID?

    struct Mark: Codable { var rating: Int; var flag: Int }

    private static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("mSIZER", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private init() {
        if let d = UserDefaults.standard.data(forKey: "rawSettings"), let s = try? JSONDecoder().decode(RawSettings.self, from: d) { settings = s } else { settings = RawSettings() }
        if let d = try? Data(contentsOf: Self.supportDir.appendingPathComponent("raw-marks.json")),
           let m = try? JSONDecoder().decode([String: Mark].self, from: d) { marks = m } else { marks = [:] }
        if settings.folder.isEmpty { settings.folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].path }
        setenv("OMP_NUM_THREADS", "1", 1)   // LibRaw : un seul fil par fichier ; le parallélisme est entre fichiers
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "rawSettings") }
    }

    // MARK: Accès

    func item(_ id: UUID) -> RawItem? { index[id].map { items[$0] } }
    var current: RawItem? { currentID.flatMap(item) }
    var visible: [RawItem] { visibleIDs.compactMap(item) }

    func count(_ f: RawFilter) -> Int { items.reduce(0) { $0 + (Self.matches($1, f) ? 1 : 0) } }

    private static func matches(_ it: RawItem, _ f: RawFilter) -> Bool {
        switch f {
        case .all: return true
        case .picks: return it.flag == .pick
        case .unflagged: return it.flag == .none
        case .rejects: return it.flag == .reject
        case .stars(let n): return it.rating >= n && it.flag != .reject
        }
    }

    private func refresh() {
        var list = items.filter { Self.matches($0, filter) }
        switch sort {
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: list.sort { $0.sortDate < $1.sortDate }
        case .rating: list.sort { ($0.rating, $1.name) > ($1.rating, $0.name) }
        }
        visibleIDs = list.map(\.id)
        if let c = currentID, !visibleIDs.contains(c) { currentID = visibleIDs.first; selection = currentID.map { [$0] } ?? [] }
        if currentID == nil { currentID = visibleIDs.first; if let c = currentID { selection = [c] } }
    }

    private func reindex() { index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) }) }

    // MARK: Ajout

    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url.path })
        let marks = self.marks
        scanning = true; summary = nil
        Task.detached(priority: .userInitiated) {
            var found: [URL] = []
            for u in urls { found += Self.rawFiles(in: u) }
            found = found.filter { !known.contains($0.path) }
            found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let chunk = 256
            var start = 0
            while start < found.count {
                let part = Array(found[start..<min(found.count, start + chunk)])
                start += chunk
                let loaded = await withTaskGroup(of: (Int, RawItem).self) { g -> [RawItem] in
                    var out = [RawItem?](repeating: nil, count: part.count)
                    var next = 0
                    func feed() { if next < part.count { let i = next; next += 1; g.addTask { (i, Self.load(part[i], marks: marks)) } } }
                    for _ in 0..<(Engine.workers * 2) { feed() }
                    while let (i, it) = await g.next() { out[i] = it; feed() }
                    return out.compactMap { $0 }
                }
                await MainActor.run { Self.shared.append(loaded) }
            }
            await MainActor.run { Self.shared.scanning = false }
        }
    }

    private func append(_ new: [RawItem]) {
        var seen = Set(items.map { $0.url.path })
        items += new.filter { seen.insert($0.url.path).inserted }
        reindex(); refresh()
    }

    nonisolated static func rawFiles(in url: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return RawEngine.isRaw(url) ? [url] : [] }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where RawEngine.isRaw(u) { out.append(u) }
        return out
    }

    nonisolated static func load(_ url: URL, marks: [String: Mark]) -> RawItem {
        var it = RawItem(url: url)
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        it.bytes = (a?[.size] as? Int64) ?? Int64((a?[.size] as? Int) ?? 0)
        it.modified = (a?[.modificationDate] as? Date) ?? .distantPast
        do { it.meta = try RawFile(url: url).meta } catch { it.readable = false; it.state = .failed(error.localizedDescription) }
        if let m = marks[url.path] { it.rating = m.rating; it.flag = RawFlag(rawValue: m.flag) ?? .none }
        else if let r = sidecarRating(url) { if r < 0 { it.flag = .reject } else { it.rating = r } }
        return it
    }

    /// Note déjà posée dans Lightroom ou Bridge (fichier .xmp à côté du RAW), en lecture seule.
    nonisolated static func sidecarRating(_ url: URL) -> Int? {
        let x = url.deletingPathExtension().appendingPathExtension("xmp")
        guard let h = try? FileHandle(forReadingFrom: x), let d = try? h.read(upToCount: 65536), let s = String(data: d, encoding: .utf8) else { return nil }
        for pat in ["xmp:Rating=\"(-?\\d)\"", "<xmp:Rating>(-?\\d)</xmp:Rating>"] {
            if let re = try? NSRegularExpression(pattern: pat), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s), let v = Int(s[r]) { return v }
        }
        return nil
    }

    func clear() { items = []; visibleIDs = []; index = [:]; selection = []; currentID = nil; summary = nil; lastOutput = nil }

    // MARK: Notation

    private var targets: [UUID] {
        if selection.count > 1 { return Array(selection) }
        return currentID.map { [$0] } ?? []
    }

    func setRating(_ r: Int) {
        for id in targets { if let i = index[id] { items[i].rating = r; if r > 0, items[i].flag == .reject { items[i].flag = .none }; mark(items[i]) } }
        afterMark()
    }

    func setFlag(_ f: RawFlag) {
        for id in targets { if let i = index[id] { items[i].flag = (items[i].flag == f && f != .none) ? .none : f; mark(items[i]) } }
        afterMark()
    }

    private func afterMark() {
        let advance = settings.autoAdvance && selection.count <= 1
        let keep = currentID
        // Le filtre actif peut faire disparaître la photo : on passe alors à la suivante au même rang.
        let pos = keep.flatMap { visibleIDs.firstIndex(of: $0) }
        refresh()
        if let c = keep, !visibleIDs.contains(c), let p = pos { let n = visibleIDs.isEmpty ? nil : visibleIDs[min(p, visibleIDs.count - 1)]; currentID = n; selection = n.map { [$0] } ?? [] }
        else if advance { move(1) }
        objectWillChange.send()
    }

    private func mark(_ it: RawItem) {
        if it.rating == 0 && it.flag == .none { marks.removeValue(forKey: it.url.path) } else { marks[it.url.path] = Mark(rating: it.rating, flag: it.flag.rawValue) }
        saveTask?.cancel()
        let snapshot = marks
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            try? JSONEncoder().encode(snapshot).write(to: Self.supportDir.appendingPathComponent("raw-marks.json"), options: .atomic)
        }
    }

    // MARK: Navigation

    func move(_ delta: Int) {
        guard !visibleIDs.isEmpty else { return }
        let i = currentID.flatMap { visibleIDs.firstIndex(of: $0) } ?? 0
        let n = visibleIDs[max(0, min(visibleIDs.count - 1, i + delta))]
        currentID = n; selection = [n]; anchor = n
    }

    func click(_ id: UUID, command: Bool, shift: Bool) {
        if shift, let a = anchor, let i = visibleIDs.firstIndex(of: a), let j = visibleIDs.firstIndex(of: id) {
            selection = Set(visibleIDs[min(i, j)...max(i, j)])
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else { selection = [id]; anchor = id }
        currentID = id
    }

    func open(_ id: UUID) { currentID = id; selection = [id]; view = .loupe }

    // MARK: Corbeille des rejetées

    var rejectedCount: Int { items.reduce(0) { $0 + ($1.flag == .reject ? 1 : 0) } }

    func trashRejected() {
        let rej = items.filter { $0.flag == .reject }
        guard !rej.isEmpty else { return }
        NSWorkspace.shared.recycle(rej.map(\.url)) { trashed, _ in
            let gone = Set(trashed.keys.map(\.path))
            Task { @MainActor in
                let s = RawStore.shared
                s.items.removeAll { gone.contains($0.url.path) }
                for p in gone { s.marks.removeValue(forKey: p) }
                s.reindex(); s.refresh()
            }
        }
    }

    // MARK: Conversion

    struct Job { let id: UUID; let src: URL; let dst: URL; let rating: Int?; let isDNG: Bool }
    enum Outcome { case done(Int), skipped(String), failed(String) }

    var scopeItems: [RawItem] {
        switch settings.scope {
        case .kept: return items.filter { $0.flag != .reject && $0.readable }
        case .picks: return items.filter { $0.flag == .pick && $0.readable }
        case .visible: return visible.filter { $0.readable }
        case .selection: return items.filter { selection.contains($0.id) && $0.readable }
        }
    }

    func pickFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        if p.runModal() == .OK { add(p.urls) }
    }

    func cancel() { batch?.cancel() }

    func convert() {
        guard !converting else { return }
        let list = scopeItems
        guard !list.isEmpty else { return }
        if settings.dest == .folder, settings.folder.isEmpty { summary = L.t("err.nofolder"); summaryWarning = true; return }
        converting = true; progress = 0; summary = nil; summaryWarning = false; lastOutput = nil
        for it in list { if let i = index[it.id] { items[i].state = .pending } }
        let st = settings
        let opts = RawConvertOptions(compressed: st.compressed, previewMax: st.previewMax, verify: st.verify, rating: nil)
        let t0 = Date()
        batch = Task.detached(priority: .userInitiated) {
            let jobs = Self.plan(list, st)
            var done = 0, failed = 0, skipped = 0, written = 0, totalBytes = 0
            let width = min(4, max(2, Engine.workers / 2))
            await withTaskGroup(of: (UUID, Outcome).self) { g in
                var next = 0
                func feed() {
                    guard next < jobs.count, !Task.isCancelled else { return }
                    let j = jobs[next]; next += 1
                    g.addTask { (j.id, Self.run(j, opts, st)) }
                }
                for _ in 0..<width { feed() }
                while let (id, out) = await g.next() {
                    done += 1
                    switch out { case .done(let b): written += 1; totalBytes += b; case .skipped: skipped += 1; case .failed: failed += 1 }
                    let d = done
                    await MainActor.run {
                        let s = Self.shared
                        if let i = s.index[id] {
                            switch out {
                            case .done(let b): s.items[i].state = .done(b)
                            case .skipped(let m): s.items[i].state = .skipped(m)
                            case .failed(let m): s.items[i].state = .failed(m)
                            }
                        }
                        s.progress = Double(d) / Double(max(1, jobs.count))
                    }
                    feed()
                }
            }
            let dt = max(0.001, Date().timeIntervalSince(t0))
            let cancelled = Task.isCancelled
            let nDone = done, nWritten = written, nSkipped = skipped, nFailed = failed
            await MainActor.run {
                let s = Self.shared
                s.converting = false; s.progress = 0
                var parts = cancelled ? [L.t("raw.sum.cancelled", nDone)] : [L.t("raw.sum.done", nWritten, String(format: "%.1f", dt), String(format: "%.1f", Double(nWritten) / dt))]
                if nSkipped > 0 { parts.append(L.t("raw.sum.skipped", nSkipped)) }
                if nFailed > 0 { parts.append(L.t("raw.sum.failed", nFailed)) }
                s.summary = parts.joined(separator: " · ")
                s.summaryWarning = nFailed > 0 || cancelled
                s.lastOutput = jobs.first(where: { j in if case .done = s.item(j.id)?.state { return true } else { return false } })?.dst
            }
        }
    }

    /// Chemins de sortie : unicité garantie dans le lot et, selon le réglage, face aux fichiers existants.
    nonisolated static func plan(_ list: [RawItem], _ st: RawSettings) -> [Job] {
        let fm = FileManager.default
        var used = Set<String>()
        var out: [Job] = []
        for it in list {
            let dir: URL
            switch st.dest {
            case .subfolder: dir = it.url.deletingLastPathComponent().appendingPathComponent("DNG", isDirectory: true)
            case .beside: dir = it.url.deletingLastPathComponent()
            case .folder: dir = URL(fileURLWithPath: st.folder, isDirectory: true)
            }
            let stem = it.url.deletingPathExtension().lastPathComponent
            var dst = dir.appendingPathComponent(stem + ".dng")
            let isDNG = it.url.pathExtension.lowercased() == "dng"
            var n = 2
            while used.contains(dst.path.lowercased()) || (st.conflict == .number && fm.fileExists(atPath: dst.path)) {
                dst = dir.appendingPathComponent("\(stem)-\(n).dng"); n += 1
            }
            used.insert(dst.path.lowercased())
            var rating: Int?
            if st.embedRating { rating = it.flag == .reject ? -1 : (it.rating > 0 ? it.rating : nil) }
            out.append(Job(id: it.id, src: it.url, dst: dst, rating: rating, isDNG: isDNG))
        }
        return out
    }

    nonisolated static func run(_ j: Job, _ base: RawConvertOptions, _ st: RawSettings) -> Outcome {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: j.dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: j.dst.path) {
                if st.conflict == .skip { return .skipped(L.t("raw.status.exists")) }
                if st.conflict == .overwrite, j.dst.path != j.src.path { try? fm.removeItem(at: j.dst) }
            }
            if j.isDNG {
                if j.dst.path == j.src.path { return .skipped(L.t("raw.status.dng")) }
                try fm.copyItem(at: j.src, to: j.dst)
                return .done(Int((try? fm.attributesOfItem(atPath: j.dst.path)[.size] as? Int) ?? 0))
            }
            var o = base; o.rating = j.rating
            return .done(try RawEngine.convert(j.src, to: j.dst, o))
        } catch { return .failed(error.localizedDescription) }
    }
}

// mSIZER — réglages de traitement et éléments de la liste.
import Foundation
import AppKit

enum ResizeMode: String, Codable, CaseIterable { case longest, width, height, percent, fit, fill }
enum CropRatio: String, Codable, CaseIterable { case square, r43, r32, r169, r45, r916, custom, manual
    /// Rapport largeur / hauteur (nil si personnalisé : voir Settings).
    var ratio: Double? {
        switch self {
        case .square: 1
        case .r43: 4.0 / 3
        case .r32: 3.0 / 2
        case .r169: 16.0 / 9
        case .r45: 4.0 / 5
        case .r916: 9.0 / 16
        case .custom, .manual: nil
        }
    }
    var label: String {
        switch self {
        case .square: "1:1"
        case .r43: "4:3"
        case .r32: "3:2"
        case .r169: "16:9"
        case .r45: "4:5"
        case .r916: "9:16"
        case .custom: L.t("crop.custom")
        case .manual: L.t("crop.manual")
        }
    }
}
/// Verrouillage du rapport pendant le recadrage manuel (« output » : rapport de la taille de sortie).
enum CropLock: String, Codable, CaseIterable { case free, square, r43, r32, r169, r45, r916, output
    var ratio: Double? {
        switch self {
        case .free, .output: nil
        case .square: 1
        case .r43: 4.0 / 3
        case .r32: 3.0 / 2
        case .r169: 16.0 / 9
        case .r45: 4.0 / 5
        case .r916: 9.0 / 16
        }
    }
    var label: String {
        switch self {
        case .free: L.t("crop.lock.free")
        case .output: L.t("crop.lock.out")
        case .square: "1:1"
        case .r43: "4:3"
        case .r32: "3:2"
        case .r169: "16:9"
        case .r45: "4:5"
        case .r916: "9:16"
        }
    }
}

/// Rectangle de recadrage en fractions de l'image (origine en haut à gauche), indépendant de la taille de la photo.
struct NormRect: Codable, Equatable {
    var x = 0.0, y = 0.0, w = 1.0, h = 1.0
    static let minSize = 0.03
    enum Handle: CaseIterable { case tl, t, tr, l, r, bl, b, br
        var left: Bool { self == .tl || self == .l || self == .bl }
        var right: Bool { self == .tr || self == .r || self == .br }
        var top: Bool { self == .tl || self == .t || self == .tr }
        var bottom: Bool { self == .bl || self == .b || self == .br }
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), max(lo, hi)) }

    /// Plus grand rectangle de rapport `ratio` (largeur/hauteur en pixels) contenu dans celui-ci, de même centre.
    /// `aspect` : largeur/hauteur de la photo.
    func fitted(to ratio: Double, aspect: Double) -> NormRect {
        var nw = w, nh = h
        if nw * aspect / nh > ratio { nw = nh * ratio / aspect } else { nh = nw * aspect / ratio }
        let cx = x + w / 2, cy = y + h / 2
        return NormRect(x: Self.clamp(cx - nw / 2, 0, 1 - nw), y: Self.clamp(cy - nh / 2, 0, 1 - nh), w: nw, h: nh)
    }

    /// Rectangle tiré depuis un coin fixe `a` jusqu'au point `p` (fractions de l'image), libre ou verrouillé au rapport `lock`.
    static func corner(from a: CGPoint, to p: CGPoint, lock: Double?, aspect: Double) -> NormRect {
        let px = clamp(p.x, 0, 1), py = clamp(p.y, 0, 1)
        let sx = px >= a.x ? 1.0 : -1.0, sy = py >= a.y ? 1.0 : -1.0
        var w = abs(px - a.x), h = abs(py - a.y)
        if let r = lock {
            let k = aspect / r                       // hauteur = largeur × k
            w = max(w, h / k)
            w = min(w, sx > 0 ? 1 - a.x : a.x, (sy > 0 ? 1 - a.y : a.y) / k)
            w = max(w, minSize); h = w * k
        } else { w = max(w, minSize); h = max(h, minSize) }
        return NormRect(x: clamp(sx > 0 ? a.x : a.x - w, 0, 1 - w), y: clamp(sy > 0 ? a.y : a.y - h, 0, 1 - h), w: w, h: h)
    }

    /// Rectangle après glissement d'une poignée jusqu'au point `p`.
    func resized(_ handle: Handle, to p: CGPoint, lock: Double?, aspect: Double) -> NormRect {
        let px = Self.clamp(p.x, 0, 1), py = Self.clamp(p.y, 0, 1)
        if let r = lock {
            let k = aspect / r
            switch handle {
            case .tl: return Self.corner(from: CGPoint(x: x + w, y: y + h), to: p, lock: lock, aspect: aspect)
            case .tr: return Self.corner(from: CGPoint(x: x, y: y + h), to: p, lock: lock, aspect: aspect)
            case .bl: return Self.corner(from: CGPoint(x: x + w, y: y), to: p, lock: lock, aspect: aspect)
            case .br: return Self.corner(from: CGPoint(x: x, y: y), to: p, lock: lock, aspect: aspect)
            case .l, .r:
                let ax = handle == .l ? x + w : x
                let nw = max(Self.minSize, min(abs(px - ax), handle == .l ? ax : 1 - ax, 1 / k)), nh = nw * k
                return NormRect(x: handle == .l ? ax - nw : ax, y: Self.clamp(y + h / 2 - nh / 2, 0, 1 - nh), w: nw, h: nh)
            case .t, .b:
                let ay = handle == .t ? y + h : y
                let nh = max(Self.minSize * k, min(abs(py - ay), handle == .t ? ay : 1 - ay, k)), nw = nh / k
                return NormRect(x: Self.clamp(x + w / 2 - nw / 2, 0, 1 - nw), y: handle == .t ? ay - nh : ay, w: nw, h: nh)
            }
        }
        var l = x, t = y, rt = x + w, b = y + h
        if handle.left { l = min(px, rt - Self.minSize) }
        if handle.right { rt = max(px, l + Self.minSize) }
        if handle.top { t = min(py, b - Self.minSize) }
        if handle.bottom { b = max(py, t + Self.minSize) }
        return NormRect(x: l, y: t, w: rt - l, h: b - t)
    }

    func moved(dx: Double, dy: Double) -> NormRect {
        NormRect(x: Self.clamp(x + dx, 0, 1 - w), y: Self.clamp(y + dy, 0, 1 - h), w: w, h: h)
    }
}
enum Rotation: Int, Codable, CaseIterable { case none = 0, cw = 90, half = 180, ccw = 270 }
enum OutFormat: String, Codable, CaseIterable { case original, jpeg, png, heic, tiff
    var label: String {
        switch self {
        case .original: L.t("fmt.original")
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        }
    }
}
/// Neuf positions : rangée = rawValue / 3 (haut, milieu, bas), colonne = rawValue % 3 (gauche, centre, droite).
enum Anchor: Int, Codable, CaseIterable { case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight }
enum WatermarkKind: String, Codable, CaseIterable { case text, image }
enum OutputMode: String, Codable, CaseIterable { case subfolder, folder, replace }
enum MetaMode: String, Codable, CaseIterable { case keep, noGPS, stripAll }

struct Settings: Codable, Equatable {
    var resizeOn = true
    var resizeMode: ResizeMode = .longest
    var resizeValue: Double = 1920
    var resizeValue2: Double = 1080          // hauteur pour « Dans un cadre » et « Remplir »
    var noEnlarge = true

    var cropOn = false
    var cropRatio: CropRatio = .square
    var cropW: Double = 16
    var cropH: Double = 10
    var cropAnchor: Anchor = .center
    var cropRect = NormRect()                // recadrage manuel (fractions de l'image tournée)
    var cropLock: CropLock = .free

    var rotateOn = false
    var rotation: Rotation = .none
    var flipH = false
    var flipV = false

    var adjustOn = false
    var autoEnhance = false
    var brightness: Double = 0               // -0.5 … 0.5
    var contrast: Double = 1                 // 0.5 … 1.5
    var saturation: Double = 1               // 0 … 2
    var sharpen: Double = 0                  // 0 … 2
    var mono = false

    var watermarkOn = false
    var wmKind: WatermarkKind = .text
    var wmText = "© "
    var wmDark = false
    var wmImagePath = ""
    var wmSize: Double = 0.2                 // part de la largeur de la photo
    var wmOpacity: Double = 0.7
    var wmAnchor: Anchor = .bottomRight
    var wmMargin: Double = 0.03              // part de la largeur de la photo

    var format: OutFormat = .jpeg
    var quality: Double = 0.82
    var maxKB: Int = 0                       // 0 : pas de limite de poids
    var toSRGB = true
    var metaMode: MetaMode = .keep

    var renameOn = false
    var pattern = "{name}"
    var startNumber = 1

    var outputMode: OutputMode = .subfolder
    var outputFolder = ""

    /// Rapport imposé au recadrage manuel (largeur/hauteur), nil si libre.
    var lockRatio: Double? {
        guard cropLock == .output else { return cropLock.ratio }
        return resizeOn && (resizeMode == .fit || resizeMode == .fill) && resizeValue > 0 && resizeValue2 > 0 ? resizeValue / resizeValue2 : nil
    }

    /// Relit des réglages enregistrés par une autre version : les clés absentes gardent leur valeur par défaut.
    static func decodeLenient(_ data: Data) -> Settings? {
        guard var base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for (k, v) in saved where base[k] != nil { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: merged)
    }

    /// Reprend les opérations d'un préréglage sans toucher à la destination ni au logo choisis.
    func applying(preset p: Settings) -> Settings {
        var s = p
        s.outputMode = outputMode; s.outputFolder = outputFolder; s.wmImagePath = wmImagePath
        if p.wmText == Settings().wmText { s.wmText = wmText }
        return s
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: Settings
}

struct PhotoItem: Identifiable {
    enum Status: Equatable { case pending, done(bytes: Int), failed(String) }
    let id = UUID()
    let url: URL
    var width = 0
    var height = 0
    var bytes = 0
    var thumb: NSImage?
    var status: Status = .pending
    var cropRect: NormRect?                  // cadrage propre à cette photo (recadrage manuel)
    var name: String { url.lastPathComponent }
}

/// Tailles des photos et avatars des réseaux sociaux : exportées en « Remplir » à la taille exacte, avec cadrage manuel verrouillé.
enum Social {
    struct Spec: Identifiable { let kind: String; let w: Int; let h: Int; var id: String { "\(kind)\(w)x\(h)" } }
    struct Network: Identifiable { let name: String; let specs: [Spec]; var id: String { name } }

    private static func s(_ kind: String, _ w: Int, _ h: Int) -> Spec { Spec(kind: kind, w: w, h: h) }

    static let networks: [Network] = [
        Network(name: "Instagram", specs: [s("square", 1080, 1080), s("portrait", 1080, 1350), s("landscape", 1080, 566), s("story", 1080, 1920), s("profile", 320, 320)]),
        Network(name: "Facebook", specs: [s("post", 1200, 630), s("story", 1080, 1920), s("cover", 1640, 624), s("profile", 400, 400)]),
        Network(name: "X", specs: [s("post", 1600, 900), s("banner", 1500, 500), s("profile", 400, 400)]),
        Network(name: "LinkedIn", specs: [s("post", 1200, 627), s("banner", 1584, 396), s("profile", 400, 400)]),
        Network(name: "YouTube", specs: [s("thumb", 1280, 720), s("banner", 2560, 1440), s("profile", 800, 800)]),
        Network(name: "TikTok", specs: [s("story", 1080, 1920), s("profile", 200, 200)]),
        Network(name: "Pinterest", specs: [s("pin", 1000, 1500), s("profile", 400, 400)]),
        Network(name: "Snapchat", specs: [s("story", 1080, 1920)]),
        Network(name: "WhatsApp", specs: [s("profile", 500, 500)]),
        Network(name: "Discord", specs: [s("profile", 512, 512), s("banner", 960, 540)]),
        Network(name: "Twitch", specs: [s("profile", 256, 256), s("banner", 1200, 480)]),
    ]

    static func settings(_ spec: Spec) -> Settings {
        var s = Settings()
        s.resizeOn = true; s.resizeMode = .fill; s.resizeValue = Double(spec.w); s.resizeValue2 = Double(spec.h); s.noEnlarge = false
        s.cropOn = true; s.cropRatio = .manual; s.cropLock = .output
        s.format = .jpeg; s.quality = 0.9; s.metaMode = .noGPS
        return s
    }
}

enum Format {
    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

/// Compare deux numéros de version « 1.2.3 » (un éventuel « v » initial est ignoré).
enum VersionCompare {
    static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

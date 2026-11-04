// mSIZER — réglages de traitement et éléments de la liste.
import Foundation
import AppKit

enum ResizeMode: String, Codable, CaseIterable { case longest, width, height, percent, fit, fill }
enum CropRatio: String, Codable, CaseIterable { case square, r43, r32, r169, r45, r916, custom
    /// Rapport largeur / hauteur (nil si personnalisé : voir Settings).
    var ratio: Double? {
        switch self {
        case .square: 1
        case .r43: 4.0 / 3
        case .r32: 3.0 / 2
        case .r169: 16.0 / 9
        case .r45: 4.0 / 5
        case .r916: 9.0 / 16
        case .custom: nil
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
        }
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
    var name: String { url.lastPathComponent }
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

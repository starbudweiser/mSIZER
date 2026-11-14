// mSIZER — lecture des fichiers RAW (LibRaw, liée statiquement) : métadonnées, aperçu intégré, données du capteur.
import Foundation
import ImageIO
import CoreGraphics
import Darwin

enum RawError: Error, LocalizedError {
    case open(String), unsupported(String), unpack(String), write(String), verify
    var errorDescription: String? {
        switch self {
        case .open(let s): return L.t("raw.err.open", s)
        case .unsupported(let s): return L.t("raw.err.unsupported", s)
        case .unpack(let s): return L.t("raw.err.unpack", s)
        case .write(let s): return L.t("raw.err.write", s)
        case .verify: return L.t("raw.err.verify")
        }
    }
}

/// Informations de prise de vue, lues sans décoder les pixels.
struct RawMeta: Equatable {
    var make = "", model = "", lens = ""
    var iso: Float = 0, shutter: Float = 0, aperture: Float = 0, focal: Float = 0
    var date: Date?
    var width = 0, height = 0          // zone visible, avant rotation
    var flip = 0
    var isDNG = false
    var camera: String { model.isEmpty ? make : (model.lowercased().hasPrefix(make.lowercased()) || make.isEmpty ? model : "\(make) \(model)") }
    /// Dimensions telles qu'affichées (rotation appliquée).
    var displayW: Int { [5, 6].contains(flip) ? height : width }
    var displayH: Int { [5, 6].contains(flip) ? width : height }
    var shutterText: String {
        guard shutter > 0 else { return "" }
        return shutter >= 1 ? String(format: "%.1f s", shutter) : "1/\(Int((1 / shutter).rounded())) s"
    }
}

/// Un fichier RAW ouvert : le fichier est projeté en mémoire (mmap), LibRaw lit dedans sans copie.
final class RawFile {
    private let lr: UnsafeMutablePointer<libraw_data_t>
    private let map: UnsafeMutableRawPointer
    private let size: Int
    private var unpacked = false

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw RawError.open(String(cString: strerror(errno))) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { throw RawError.open("vide") }
        size = Int(st.st_size)
        guard let m = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), m != MAP_FAILED else { throw RawError.open(String(cString: strerror(errno))) }
        map = m
        guard let l = libraw_init(0) else { munmap(m, size); throw RawError.open("LibRaw") }
        lr = l
        let r = libraw_open_buffer(lr, map, size)
        if r != 0 {
            let msg = String(cString: libraw_strerror(r))
            libraw_close(lr); munmap(map, size)
            throw RawError.open(msg)
        }
    }

    deinit { libraw_close(lr); munmap(map, size) }

    private func str(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(cString: p).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var meta: RawMeta {
        var m = RawMeta()
        m.make = str(rs_nmake(lr)); if m.make.isEmpty { m.make = str(rs_make(lr)) }
        m.model = str(rs_nmodel(lr)); if m.model.isEmpty { m.model = str(rs_model(lr)) }
        m.lens = str(rs_lens(lr))
        m.iso = rs_iso(lr); m.shutter = rs_shutter(lr); m.aperture = rs_aperture(lr); m.focal = rs_focal(lr)
        let t = rs_timestamp(lr); if t > 0 { m.date = Date(timeIntervalSince1970: TimeInterval(t)) }
        m.width = Int(rs_w(lr)); m.height = Int(rs_h(lr)); m.flip = Int(rs_flip(lr))
        m.isDNG = rs_dng_version(lr) != 0
        return m
    }

    // MARK: Aperçu intégré

    /// JPEG d'aperçu incorporé au RAW (rapide : aucune lecture des pixels du capteur).
    func previewJPEG() -> Data? {
        guard libraw_unpack_thumb(lr) == 0, rs_thumb_format(lr) == 1, let p = rs_thumb_data(lr), rs_thumb_len(lr) > 0 else { return nil }
        return Data(bytes: p, count: Int(rs_thumb_len(lr)))
    }

    /// Aperçu RVB brut (certains boîtiers n'incorporent pas de JPEG).
    func previewBitmap() -> CGImage? {
        guard libraw_unpack_thumb(lr) == 0, rs_thumb_format(lr) == 2, let p = rs_thumb_data(lr) else { return nil }
        let w = Int(rs_thumb_w(lr)), h = Int(rs_thumb_h(lr))
        guard w > 0, h > 0, Int(rs_thumb_len(lr)) >= w * h * 3 else { return nil }
        let data = Data(bytes: p, count: w * h * 3)
        guard let prov = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Capteur

    /// Décode les données du capteur (non démosaïquées). Échoue pour les capteurs non à matrice de Bayer / X-Trans.
    func unpack() throws {
        if unpacked { return }
        let r = libraw_unpack(lr)
        if r != 0 { throw RawError.unpack(String(cString: libraw_strerror(r))) }
        unpacked = true
    }

    /// Données du capteur décodées : valide jusqu'à la destruction de l'objet.
    var sensor: Sensor? {
        guard unpacked, let p = rs_raw(lr) else { return nil }
        return Sensor(pixels: p, width: Int(rs_raw_w(lr)), height: Int(rs_raw_h(lr)), stride: Int(rs_raw_pitch(lr)) / 2)
    }

    struct Sensor { let pixels: UnsafePointer<UInt16>; let width: Int; let height: Int; let stride: Int }

    /// Paramètres colorimétriques et géométriques pour le DNG.
    func dngInfo() throws -> DNGInfo {
        var d = DNGInfo()
        let filters = rs_filters(lr)
        d.rawW = Int(rs_raw_w(lr)); d.rawH = Int(rs_raw_h(lr))
        d.activeTop = Int(rs_top(lr)); d.activeLeft = Int(rs_left(lr))
        d.visibleW = Int(rs_w(lr)); d.visibleH = Int(rs_h(lr))
        if rs_is_foveon(lr) != 0 { throw RawError.unsupported("Foveon") }
        if rs_colors(lr) != 3 && filters != 9 { throw RawError.unsupported(String(format: "%d couleurs", rs_colors(lr))) }
        if filters == 0 { throw RawError.unsupported("non CFA") }
        let top = d.activeTop, left = d.activeLeft
        if filters == 9 {
            d.cfaDim = 6
            // Le motif X-Trans est donné par rapport à la zone visible : on le ramène à l'origine du capteur.
            for r in 0..<6 { for c in 0..<6 {
                let v = Int(rs_xtrans(lr, Int32((r - top % 6 + 6) % 6), Int32((c - left % 6 + 6) % 6)))
                d.cfa.append(UInt8(v == 3 ? 1 : v))
            } }
        } else {
            d.cfaDim = 2
            for r in 0..<2 { for c in 0..<2 {
                let v = Int(libraw_COLOR(lr, Int32((r - top % 2 + 2) % 2), Int32((c - left % 2 + 2) % 2)))
                d.cfa.append(UInt8(v == 3 ? 1 : min(v, 2)))
            } }
        }
        // Niveaux de noir par case du motif (noir global + noir par canal + éventuel motif de noir).
        let n = d.cfaDim
        let black = Double(rs_black(lr))
        let pr = Int(rs_cblack(lr, 4)), pc = Int(rs_cblack(lr, 5))
        for r in 0..<n { for c in 0..<n {
            let k = Int(libraw_COLOR(lr, Int32((r - top % n + n * 2) % n), Int32((c - left % n + n * 2) % n)))
            var b = black + Double(rs_cblack(lr, Int32(min(k, 3))))
            if pr > 0 && pc > 0 { b += Double(rs_cblack(lr, Int32(6 + (r % pr) * pc + (c % pc)))) }
            d.black.append(b)
        } }
        var white = Double(rs_maximum(lr))
        if white <= (d.black.max() ?? 0) { white = Double(rs_data_maximum(lr)) }
        if white <= (d.black.max() ?? 0) { white = 65535 }
        d.white = white

        // Balance des blancs de la prise de vue : multiplicateurs → neutre.
        let m0 = Double(rs_cam_mul(lr, 0)), m1 = Double(rs_cam_mul(lr, 1)), m2 = Double(rs_cam_mul(lr, 2))
        if m0 > 0, m1 > 0, m2 > 0 { d.asShot = [m1 / m0, 1, m1 / m2] }

        // Matrice XYZ → appareil : celle du DNG source si présente, sinon celle de la table LibRaw.
        func mat(_ f: (Int32, Int32) -> Float) -> [Double] {
            var o: [Double] = []
            for r in 0..<3 { for c in 0..<3 { o.append(Double(f(Int32(r), Int32(c)))) } }
            return o
        }
        let fromDNG = mat { rs_dng_cm(lr, $0, $1) }
        let fromTable = mat { rs_cam_xyz(lr, $0, $1) }
        if fromDNG.contains(where: { abs($0) > 1e-6 }) { d.colorMatrix = fromDNG }
        else if fromTable.contains(where: { abs($0) > 1e-6 }) { d.colorMatrix = fromTable }
        else { d.colorMatrix = nil }
        d.orientation = [0: 1, 3: 3, 5: 8, 6: 6][Int(rs_flip(lr))] ?? 1
        return d
    }
}

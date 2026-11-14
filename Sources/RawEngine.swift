// mSIZER — conversion RAW → DNG : décodage LibRaw, aperçu intégré, écriture DNG, vérification par relecture.
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

struct RawConvertOptions {
    var compressed = true
    var previewMax = 1600          // 0 : sans aperçu
    var verify = false
    var rating: Int?
}

enum RawEngine {
    static let extensions: Set<String> = ["rw2", "raw", "rwl", "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "pef", "srw",
                                          "3fr", "fff", "iiq", "erf", "mef", "mos", "mrw", "kdc", "dcr", "x3f", "rwz", "gpr", "cap", "eip", "ari", "bay", "cs1", "dc2", "k25"]

    static func isRaw(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    private static func inverse(_ o: Int) -> Int { o == 6 ? 8 : o == 8 ? 6 : o }

    /// Aperçu JPEG redimensionné, rangé comme le capteur : l'étiquette Orientation du DNG s'applique à l'image et à son aperçu (convention d'Adobe).
    static func preview(of file: RawFile, maxSide: Int, dngOrientation: Int) -> DNGPreview? {
        guard maxSide > 0 else { return nil }
        var cg: CGImage?
        if let jpeg = file.previewJPEG(), let src = CGImageSourceCreateWithData(jpeg as CFData, nil) {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let oj = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                                            kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary)
            if let c = cg, oj != dngOrientation {
                // L'orientation du JPEG diffère de celle du RAW : on passe par l'image droite, puis on la remet « en position capteur ».
                let upright = CIImage(cgImage: c).oriented(forExifOrientation: Int32(oj)).oriented(forExifOrientation: Int32(inverse(dngOrientation)))
                cg = ciContext.createCGImage(upright, from: upright.extent)
            }
        } else if let b = file.previewBitmap() {
            let upright = CIImage(cgImage: b).oriented(forExifOrientation: Int32(inverse(dngOrientation)))
            cg = ciContext.createCGImage(upright, from: upright.extent)
        }
        guard let img = cg else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return DNGPreview(jpeg: data as Data, width: img.width, height: img.height)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Convertit « src » en « dst » (DNG). Retourne la taille écrite.
    static func convert(_ src: URL, to dst: URL, _ o: RawConvertOptions) throws -> Int {
        let f = try RawFile(url: src)
        try f.unpack()
        guard let sensor = f.sensor else { throw RawError.unsupported("capteur") }
        let info = try f.dngInfo()
        let meta = f.meta
        let pv = preview(of: f, maxSide: o.previewMax, dngOrientation: info.orientation)
        let bytes = try DNGWriter.write(to: dst, sensor: sensor, info: info, meta: meta, preview: pv, opts: DNGOptions(compressed: o.compressed, rating: o.rating))
        if o.verify {
            do { try verify(dst, against: sensor) } catch { try? FileManager.default.removeItem(at: dst); throw error }
        }
        return bytes
    }

    /// Relit le DNG avec LibRaw (décodeur indépendant du nôtre) et compare chaque pixel du capteur.
    static func verify(_ dng: URL, against s: RawFile.Sensor) throws {
        let g = try RawFile(url: dng)
        try g.unpack()
        guard let t = g.sensor, t.width == s.width, t.height == s.height else {
            if ProcessInfo.processInfo.environment["RAWDEBUG"] != nil { print("dims", g.sensor?.width ?? -1, g.sensor?.height ?? -1, "attendu", s.width, s.height) }
            throw RawError.verify
        }
        for r in 0..<s.height {
            if memcmp(s.pixels + r * s.stride, t.pixels + r * t.stride, s.width * 2) != 0 {
                if ProcessInfo.processInfo.environment["RAWDEBUG"] != nil {
                    var x = 0
                    while s.pixels[r * s.stride + x] == t.pixels[r * t.stride + x] { x += 1 }
                    print("différence ligne", r, "col", x, "source", s.pixels[r * s.stride + x], "relu", t.pixels[r * t.stride + x])
                }
                throw RawError.verify
            }
        }
    }
}

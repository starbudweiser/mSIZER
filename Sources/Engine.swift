// mSIZER — moteur de traitement : Core Image (GPU via Metal) pour les filtres, ImageIO (décodage JPEG/HEIC matériel) pour
// la lecture et l'écriture. Les photos sont traitées en parallèle sur les cœurs performance de la puce Apple.
import Foundation
import CoreImage
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Géométrie du traitement, calculée sans toucher à l'image (testable).
struct Plan: Equatable {
    var rotatedW: Int, rotatedH: Int          // dimensions après rotation
    var crop: CGRect                          // recadrage, origine en haut à gauche, repère de l'image tournée
    var preW: Int, preH: Int                  // taille après redimensionnement, avant le cadrage final
    var finalCrop: CGRect?                    // cadrage final (mode « Remplir »), origine en haut à gauche
    var outW: Int, outH: Int
    var scale: Double { Double(preW) / crop.width }
}

struct Prepared {
    var watermark: CIImage?
}

struct JobResult {
    var url: URL?
    var bytesOut = 0
    var error: String?
    var note: String?
}

enum EngineError: LocalizedError {
    case unreadable, encode, trash(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: L.t("err.read")
        case .encode: L.t("err.encode")
        case .trash(let m): L.t("err.trash", m)
        }
    }
}

enum Engine {
    static let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Nombre de photos traitées en même temps : les cœurs performance (les cœurs efficacité restent au reste du système).
    static let workers: Int = {
        var n: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()

    // MARK: Géométrie

    static func plan(width: Int, height: Int, _ s: Settings) -> Plan {
        var w = Double(width), h = Double(height)
        if s.rotateOn, s.rotation == .cw || s.rotation == .ccw { swap(&w, &h) }
        let ax = [0.0, 0.5, 1.0][s.cropAnchor.rawValue % 3], ay = [0.0, 0.5, 1.0][s.cropAnchor.rawValue / 3]
        var crop = CGRect(x: 0, y: 0, width: w, height: h)
        if s.cropOn, let r = s.cropRatio.ratio ?? (s.cropH > 0 ? s.cropW / s.cropH : nil), r > 0 {
            var cw = w, ch = h
            if w / h > r { cw = (h * r).rounded() } else { ch = (w / r).rounded() }
            cw = max(1, min(w, cw)); ch = max(1, min(h, ch))
            crop = CGRect(x: ((w - cw) * ax).rounded(), y: ((h - ch) * ay).rounded(), width: cw, height: ch)
        }
        let cw = crop.width, ch = crop.height
        var scale = 1.0
        let v = s.resizeValue, v2 = s.resizeValue2
        if s.resizeOn, v > 0 {
            switch s.resizeMode {
            case .longest: scale = v / max(cw, ch)
            case .width: scale = v / cw
            case .height: scale = v / ch
            case .percent: scale = v / 100
            case .fit: scale = v2 > 0 ? min(v / cw, v2 / ch) : v / cw
            case .fill: scale = v2 > 0 ? max(v / cw, v2 / ch) : v / cw
            }
            if s.noEnlarge { scale = min(scale, 1) }
        }
        let preW = max(1, Int((cw * scale).rounded())), preH = max(1, Int((ch * scale).rounded()))
        var outW = preW, outH = preH
        var finalCrop: CGRect?
        if s.resizeOn, s.resizeMode == .fill, v > 0, v2 > 0 {
            let tw = min(Int(v), preW), th = min(Int(v2), preH)
            if tw < preW || th < preH {
                finalCrop = CGRect(x: ((Double(preW - tw)) * ax).rounded(), y: ((Double(preH - th)) * ay).rounded(), width: Double(tw), height: Double(th))
                outW = tw; outH = th
            }
        }
        return Plan(rotatedW: Int(w), rotatedH: Int(h), crop: crop, preW: preW, preH: preH, finalCrop: finalCrop, outW: outW, outH: outH)
    }

    // MARK: Préparation (une fois par lot)

    static func prepare(_ s: Settings) -> Prepared {
        guard s.watermarkOn else { return Prepared() }
        switch s.wmKind {
        case .text:
            let t = s.wmText.trimmingCharacters(in: .whitespacesAndNewlines)
            return Prepared(watermark: t.count > 0 ? textImage(t, dark: s.wmDark) : nil)
        case .image:
            guard !s.wmImagePath.isEmpty else { return Prepared() }
            return Prepared(watermark: CIImage(contentsOf: URL(fileURLWithPath: s.wmImagePath), options: [.applyOrientationProperty: true]))
        }
    }

    /// Texte rendu en grand corps (CoreText, sûr hors du fil principal) ; il est mis à l'échelle au moment de l'apposer.
    static func textImage(_ text: String, dark: Bool) -> CIImage? {
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 120, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let pad: CGFloat = 16
        let w = Int(ceil(b.width + 2 * pad)), h = Int(ceil(b.height + 2 * pad))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let shadow = CGColor(gray: dark ? 1 : 0, alpha: 0.45)
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 7, color: shadow)
        ctx.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1))
        ctx.textPosition = CGPoint(x: pad - b.minX, y: pad - b.minY)
        CTLineDraw(line, ctx)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    // MARK: Lecture + filtres

    struct Rendered {
        var image: CIImage
        var width: Int, height: Int
        var props: [String: Any]
        var colorSpace: CGColorSpace
        var sourceType: UTType?
    }

    private static func origin(_ ci: CIImage) -> CIImage {
        ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
    }

    private static func scaled(_ ci: CIImage, toW w: Int, h: Int) -> CIImage {
        let cw = ci.extent.width, ch = ci.extent.height
        if Int(cw) == w && Int(ch) == h { return ci }
        let sy = Double(h) / ch, sx = Double(w) / cw
        let out = ci.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        return origin(out.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: w, height: h)))
    }

    static func render(_ url: URL, _ s: Settings, _ prep: Prepared, previewMax: Int? = nil) throws -> Rendered {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw EngineError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        let pw = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let ph = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        guard pw > 0, ph > 0 else { throw EngineError.unreadable }
        let orient = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        let (ow, oh) = orient >= 5 ? (ph, pw) : (pw, ph)
        let p = plan(width: ow, height: oh, s)

        var ci: CIImage
        let direct = s.resizeOn && !s.cropOn && s.resizeMode != .fill && p.scale < 1
        if direct {
            // Réduction faite par le décodeur (JPEG : mise à l'échelle DCT, HEIC : décodage matériel) : bien plus rapide.
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: max(p.preW, p.preH), kCGImageSourceShouldCacheImmediately: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw EngineError.unreadable }
            ci = CIImage(cgImage: cg)
        } else {
            guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw EngineError.unreadable }
            ci = full
        }
        ci = origin(ci)

        if s.rotateOn {
            if s.flipH { ci = origin(ci.oriented(.upMirrored)) }
            if s.flipV { ci = origin(ci.oriented(.downMirrored)) }
            switch s.rotation {
            case .cw: ci = origin(ci.oriented(.right))
            case .ccw: ci = origin(ci.oriented(.left))
            case .half: ci = origin(ci.oriented(.down))
            case .none: break
            }
        }
        if s.cropOn {
            let r = p.crop, hh = ci.extent.height
            ci = origin(ci.cropped(to: CGRect(x: r.minX, y: hh - r.maxY, width: r.width, height: r.height)))
        }
        ci = scaled(ci, toW: p.preW, h: p.preH)
        if let f = p.finalCrop {
            ci = origin(ci.cropped(to: CGRect(x: f.minX, y: CGFloat(p.preH) - f.maxY, width: f.width, height: f.height)))
        }
        if let m = previewMax, max(p.outW, p.outH) > m {
            let k = Double(m) / Double(max(p.outW, p.outH))
            ci = scaled(ci, toW: max(1, Int(Double(p.outW) * k)), h: max(1, Int(Double(p.outH) * k)))
        }

        if s.adjustOn {
            if s.autoEnhance {
                for f in ci.autoAdjustmentFilters(options: [.redEye: false]) {
                    f.setValue(ci, forKey: kCIInputImageKey)
                    ci = f.outputImage ?? ci
                }
            }
            if s.brightness != 0 || s.contrast != 1 || s.saturation != 1 || s.mono {
                ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: s.brightness, kCIInputContrastKey: s.contrast,
                                                                       kCIInputSaturationKey: s.mono ? 0 : s.saturation])
            }
            if s.sharpen > 0 { ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: s.sharpen]) }
        }
        if s.watermarkOn, let wm = prep.watermark { ci = stamp(ci, wm, s) }

        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        let space: CGColorSpace = s.toSRGB ? srgb : (ci.colorSpace ?? srgb)
        return Rendered(image: ci, width: w, height: h, props: props, colorSpace: space, sourceType: CGImageSourceGetType(src).flatMap { UTType($0 as String) })
    }

    private static func stamp(_ base: CIImage, _ wm: CIImage, _ s: Settings) -> CIImage {
        let W = base.extent.width, H = base.extent.height
        var mark = origin(wm)
        let k = min(W * s.wmSize / mark.extent.width, H * 0.8 / mark.extent.height)
        mark = origin(mark.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1]))
        if s.wmOpacity < 1 {
            mark = mark.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: s.wmOpacity)])
        }
        let mw = mark.extent.width, mh = mark.extent.height, m = W * s.wmMargin
        let col = Double(s.wmAnchor.rawValue % 3) / 2, row = Double(s.wmAnchor.rawValue / 3) / 2
        let x = m + (W - mw - 2 * m) * col
        let yTop = m + (H - mh - 2 * m) * row
        return mark.transformed(by: CGAffineTransform(translationX: x, y: H - yTop - mh)).composited(over: base).cropped(to: base.extent)
    }

    // MARK: Encodage

    static func targetType(_ s: Settings, source: UTType?) -> UTType {
        switch s.format {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .original:
            if let t = source, [UTType.jpeg, .png, .heic, .tiff].contains(t) { return t }
            return .jpeg
        }
    }

    static func extensionFor(_ t: UTType, original: URL, format: OutFormat) -> String {
        if format == .original, UTType(filenameExtension: original.pathExtension) == t { return original.pathExtension }
        switch t {
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        default: return t.preferredFilenameExtension ?? "jpg"
        }
    }

    static func metadata(_ r: Rendered, _ s: Settings) -> [String: Any] {
        guard s.metaMode != .stripAll else { return [:] }
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary] {
            if let d = r.props[key as String] { out[key as String] = d }
        }
        if s.metaMode == .noGPS { out.removeValue(forKey: kCGImagePropertyGPSDictionary as String) }
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = r.width
            exif[kCGImagePropertyExifPixelYDimension as String] = r.height
            out[kCGImagePropertyExifDictionary as String] = exif
        }
        out[kCGImagePropertyOrientation as String] = 1
        return out
    }

    static func encode(_ cg: CGImage, type: UTType, quality: Double, maxKB: Int, props: [String: Any]) -> (data: Data, limitReached: Bool)? {
        func once(_ q: Double?) -> Data? {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            var p = props
            if let q { p[kCGImageDestinationLossyCompressionQuality as String] = q }
            CGImageDestinationAddImage(dest, cg, p as CFDictionary)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        }
        let lossy = type == .jpeg || type == .heic
        guard lossy else { return once(nil).map { ($0, true) } }
        guard var best = once(quality) else { return nil }
        guard maxKB > 0, best.count > maxKB * 1000 else { return (best, true) }
        // Recherche dichotomique de la meilleure qualité qui tient dans la limite.
        var lo = 0.05, hi = quality
        guard let floor = once(lo) else { return (best, false) }
        if floor.count > maxKB * 1000 { return (floor, false) }
        best = floor
        for _ in 0..<7 {
            let mid = (lo + hi) / 2
            guard let d = once(mid) else { break }
            if d.count <= maxKB * 1000 { best = d; lo = mid } else { hi = mid }
        }
        return (best, true)
    }

    // MARK: Un travail complet : photo → fichier

    private static let dateStamp: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }()

    static func fileStem(for url: URL, index: Int, w: Int, h: Int, _ s: Settings) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        guard s.renameOn, !s.pattern.isEmpty else { return base }
        let n = String(format: "%03d", s.startNumber + index)
        let out = s.pattern.replacingOccurrences(of: "{name}", with: base).replacingOccurrences(of: "{n}", with: n)
            .replacingOccurrences(of: "{date}", with: dateStamp).replacingOccurrences(of: "{w}", with: String(w))
            .replacingOccurrences(of: "{h}", with: String(h))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? base : trimmed
    }

    static func process(_ url: URL, index: Int, _ s: Settings, _ prep: Prepared) -> JobResult {
        autoreleasepool {
            do {
                let r = try render(url, s, prep)
                let type = targetType(s, source: r.sourceType)
                var img = r.image
                if type == .jpeg {      // JPEG sans transparence : fond blanc
                    img = img.composited(over: CIImage(color: .white).cropped(to: img.extent))
                }
                guard let cg = context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: r.colorSpace) else { throw EngineError.encode }
                guard let (data, reached) = encode(cg, type: type, quality: s.quality, maxKB: s.maxKB, props: metadata(r, s)) else { throw EngineError.encode }

                let ext = extensionFor(type, original: url, format: s.format)
                let stem = fileStem(for: url, index: index, w: r.width, h: r.height, s)
                let dir: URL
                switch s.outputMode {
                case .subfolder: dir = url.deletingLastPathComponent().appendingPathComponent("mSIZER", isDirectory: true)
                case .folder: dir = URL(fileURLWithPath: s.outputFolder, isDirectory: true)
                case .replace: dir = url.deletingLastPathComponent()
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let out = try write(data, dir: dir, stem: stem, ext: ext, replacing: s.outputMode == .replace ? url : nil)
                return JobResult(url: out, bytesOut: data.count, error: nil, note: reached ? nil : L.t("err.limit"))
            } catch {
                return JobResult(url: nil, bytesOut: 0, error: error.localizedDescription, note: nil)
            }
        }
    }

    /// Écrit sans jamais écraser : un nom pris reçoit un numéro. Pour « remplacer », l'original part à la corbeille
    /// seulement après l'écriture réussie de la nouvelle version.
    static func write(_ data: Data, dir: URL, stem: String, ext: String, replacing original: URL?) throws -> URL {
        let fm = FileManager.default
        var tmp: URL?
        if original != nil {
            let t = dir.appendingPathComponent(".mSIZER-\(UUID().uuidString).tmp")
            try data.write(to: t)
            tmp = t
            do { try fm.trashItem(at: original!, resultingItemURL: nil) } catch {
                try? fm.removeItem(at: t)
                throw EngineError.trash(error.localizedDescription)
            }
        }
        var i = 0
        while true {
            let name = i == 0 ? "\(stem).\(ext)" : "\(stem)-\(i).\(ext)"
            let dest = dir.appendingPathComponent(name)
            do {
                if let tmp { try fm.moveItem(at: tmp, to: dest) } else { try data.write(to: dest, options: .withoutOverwriting) }
                return dest
            } catch let e as CocoaError where e.code == .fileWriteFileExists || e.code == .fileWriteUnknown && fm.fileExists(atPath: dest.path) {
                i += 1
                if i > 9999 { throw e }
            } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError {
                i += 1
            }
        }
    }
}

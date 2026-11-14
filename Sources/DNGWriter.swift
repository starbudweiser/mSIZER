// mSIZER — écriture de fichiers DNG (conteneur TIFF + JPEG sans perte) : conversion RAW → DNG rapide, sans démosaïquage.
import Foundation
import Dispatch

struct DNGInfo {
    var rawW = 0, rawH = 0
    var activeTop = 0, activeLeft = 0, visibleW = 0, visibleH = 0
    var cfaDim = 2
    var cfa: [UInt8] = []
    var black: [Double] = []
    var white = 65535.0
    var asShot: [Double]?
    var colorMatrix: [Double]?
    var orientation = 1
}

struct DNGOptions {
    var compressed = true
    var rating: Int?          // −1 rejeté, 0…5 étoiles ; nil : pas de note
}

struct DNGPreview { let jpeg: Data; let width: Int; let height: Int }

enum DNGWriter {
    // MARK: Entrées TIFF

    struct Tag {
        let id: UInt16, type: UInt16, count: UInt32
        var data: [UInt8]
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }

    static func byte(_ id: UInt16, _ v: [UInt8]) -> Tag { Tag(id: id, type: 1, count: UInt32(v.count), data: v) }
    static func undef(_ id: UInt16, _ v: [UInt8]) -> Tag { Tag(id: id, type: 7, count: UInt32(v.count), data: v) }
    static func ascii(_ id: UInt16, _ s: String) -> Tag { let b = Array(s.utf8) + [0]; return Tag(id: id, type: 2, count: UInt32(b.count), data: b) }
    static func short(_ id: UInt16, _ v: [Int]) -> Tag { Tag(id: id, type: 3, count: UInt32(v.count), data: v.flatMap { le16(UInt16($0)) }) }
    static func long(_ id: UInt16, _ v: [Int]) -> Tag { Tag(id: id, type: 4, count: UInt32(v.count), data: v.flatMap { le32(UInt32($0)) }) }
    static func rational(_ id: UInt16, _ v: [Double], den: UInt32 = 10000) -> Tag {
        var d: [UInt8] = []
        for x in v {
            if x == x.rounded(), abs(x) < 1e9 { d += le32(UInt32(max(0, x))) + le32(1) }
            else { d += le32(UInt32(max(0, (x * Double(den)).rounded()))) + le32(den) }
        }
        return Tag(id: id, type: 5, count: UInt32(v.count), data: d)
    }
    static func srational(_ id: UInt16, _ v: [Double], den: Int32 = 10000) -> Tag {
        var d: [UInt8] = []
        for x in v { d += le32(UInt32(bitPattern: Int32((x * Double(den)).rounded()))) + le32(UInt32(den)) }
        return Tag(id: id, type: 10, count: UInt32(v.count), data: d)
    }

    /// Taille d'une structure (IFD + valeurs hors-ligne).
    private static func size(_ tags: [Tag]) -> Int {
        var n = 2 + 12 * tags.count + 4
        for t in tags where t.data.count > 4 { n += (t.data.count + 1) & ~1 }
        return n
    }

    private static func serialize(_ tags: [Tag], at base: Int) -> [UInt8] {
        let sorted = tags.sorted { $0.id < $1.id }
        var out = le16(UInt16(sorted.count))
        var blob: [UInt8] = []
        let blobBase = base + 2 + 12 * sorted.count + 4
        for t in sorted {
            out += le16(t.id) + le16(t.type) + le32(t.count)
            if t.data.count <= 4 { out += t.data + [UInt8](repeating: 0, count: 4 - t.data.count) }
            else {
                out += le32(UInt32(blobBase + blob.count))
                blob += t.data
                if blob.count & 1 == 1 { blob.append(0) }
            }
        }
        out += le32(0)
        return out + blob
    }

    /// Taille de tuile : 256 comme Adobe, réduite (multiple de 16) pour les images plus petites qu'une tuile, car certains lecteurs
    /// (LibRaw) supposent que la tuile ne déborde pas de l'image ; 0 si l'image est trop petite pour être compressée.
    static func tileSize(_ w: Int, _ h: Int) -> Int {
        var t = 256
        if w < t || h < t { t = min(w, h) / 16 * 16 }
        if t >= 32, w == 2 * t { t -= 16 }        // largeur = 2 tuiles : LibRaw confond alors les deux composantes avec une rangée
        return t >= 16 ? t : 0
    }


    // MARK: Écriture

    /// Écrit « url » (atomiquement). Retourne la taille du fichier.
    @discardableResult
    static func write(to url: URL, sensor: RawFile.Sensor, info: DNGInfo, meta: RawMeta, preview: DNGPreview?, opts: DNGOptions) throws -> Int {
        let w = sensor.width, h = sensor.height
        // 1. Données du capteur.
        let tileSize = Self.tileSize(w, h)
        let compressed = opts.compressed && tileSize > 0
        var strips: [Data] = []
        if compressed { strips = LJPEG.encodeTiles(pix: sensor.pixels, stride: sensor.stride, width: w, height: h, tile: tileSize) }

        // 2. Étiquettes (deux passes : les tailles ne dépendent pas des décalages).
        func make(exifOff: Int, subOff: Int, previewOff: Int, stripOffs: [Int]) -> (ifd0: [Tag], exif: [Tag], sub: [Tag]) {
            let cd = info.cfaDim
            var t: [Tag] = [
                long(254, [0]), long(256, [w]), long(257, [h]), short(258, [16]),
                short(259, [compressed ? 7 : 1]), short(262, [32803]),
                short(274, [info.orientation]), short(277, [1]),
                short(284, [1]),
                ascii(271, meta.make), ascii(272, meta.model), ascii(305, "mSIZER"),
                short(33421, [cd, cd]), byte(33422, info.cfa),
                byte(50706, [1, 4, 0, 0]), byte(50707, [1, 1, 0, 0]),
                ascii(50708, meta.camera),
                byte(50710, [0, 1, 2]), short(50711, [1]),
                short(50713, [cd, cd]), rational(50714, info.black, den: 256),
                long(50717, [Int(info.white)]),
                rational(50718, [1, 1]),
                long(50829, [info.activeTop, info.activeLeft, info.activeTop + info.visibleH, info.activeLeft + info.visibleW]),
                short(50778, [21]),
                long(34665, [exifOff]),
            ]
            t.append(rational(50719, [0, 0]))
            t.append(rational(50720, [Double(info.visibleW), Double(info.visibleH)]))
            if let m = info.colorMatrix { t.append(srational(50721, m)) }
            if let a = info.asShot { t.append(rational(50728, a, den: 1_000_000)) }
            if let d = meta.date {
                t.append(ascii(306, exifDate(d)))
            }
            if preview != nil { t.append(long(330, [subOff])) }
            if compressed {
                t += [long(322, [tileSize]), long(323, [tileSize]), long(324, stripOffs), long(325, strips.map { $0.count })]
            } else {
                t += [long(273, stripOffs), long(278, [h]), long(279, [w * h * 2])]
            }
            t.append(byte(700, Array(xmp(rating: opts.rating).utf8)))
            var e: [Tag] = [undef(36864, Array("0231".utf8))]
            if meta.shutter > 0 { e.append(rational(33434, [Double(meta.shutter)], den: 1_000_000)) }
            if meta.aperture > 0 { e.append(rational(33437, [Double(meta.aperture)], den: 10)) }
            if meta.iso > 0 { e.append(short(34855, [Int(meta.iso)])) }
            if let d = meta.date { e.append(ascii(36867, exifDate(d))); e.append(ascii(36868, exifDate(d))) }
            if meta.focal > 0 { e.append(rational(37386, [Double(meta.focal)], den: 10)) }
            if !meta.lens.isEmpty { e.append(ascii(42036, meta.lens)) }
            var s: [Tag] = []
            if let p = preview {
                s = [long(254, [1]), long(256, [p.width]), long(257, [p.height]), short(258, [8, 8, 8]), short(259, [7]), short(262, [6]),
                     long(273, [previewOff]), short(277, [3]), long(278, [p.height]), long(279, [p.jpeg.count]), short(284, [1]),
                     rational(529, [0.299, 0.587, 0.114], den: 1000), short(530, [2, 2]), short(531, [1]),
                     rational(532, [0, 255, 128, 255, 128, 255])]
            }
            return (t, e, s)
        }
        let probe = make(exifOff: 0, subOff: 0, previewOff: 0, stripOffs: [Int](repeating: 0, count: compressed ? strips.count : 1))
        let s0 = size(probe.ifd0), sE = size(probe.exif), sS = preview == nil ? 0 : size(probe.sub)
        let exifOff = 8 + s0, subOff = exifOff + sE
        var cursor = subOff + sS
        let previewOff = cursor
        if let p = preview { cursor += (p.jpeg.count + 1) & ~1 }
        var offs: [Int] = []
        if compressed { for s in strips { offs.append(cursor); cursor += (s.count + 1) & ~1 } } else { offs = [cursor]; cursor += w * h * 2 }
        let final = make(exifOff: exifOff, subOff: subOff, previewOff: previewOff, stripOffs: offs)

        var head: [UInt8] = [0x49, 0x49, 42, 0] + le32(8)
        head += serialize(final.ifd0, at: 8)
        head += serialize(final.exif, at: exifOff)
        if preview != nil { head += serialize(final.sub, at: subOff) }

        // 3. Fichier temporaire puis renommage.
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw RawError.write(String(cString: strerror(errno))) }
        var ok = true
        func put(_ p: UnsafeRawPointer, _ n: Int) {
            var done = 0
            while done < n && ok {
                let r = Darwin.write(fd, p + done, n - done)
                if r <= 0 { ok = false; break }
                done += r
            }
        }
        head.withUnsafeBytes { put($0.baseAddress!, head.count) }
        if let p = preview {
            p.jpeg.withUnsafeBytes { put($0.baseAddress!, p.jpeg.count) }
            if p.jpeg.count & 1 == 1 { var z: UInt8 = 0; put(&z, 1) }
        }
        if compressed {
            for s in strips {
                s.withUnsafeBytes { put($0.baseAddress!, s.count) }
                if s.count & 1 == 1 { var z: UInt8 = 0; put(&z, 1) }
            }
        } else {
            var line = [UInt8](repeating: 0, count: w * 2)
            for r in 0..<h {
                let row = sensor.pixels + r * sensor.stride
                line.withUnsafeMutableBytes { dst in
                    let d = dst.bindMemory(to: UInt16.self)
                    for x in 0..<w { d[x] = row[x].littleEndian }
                    put(dst.baseAddress!, w * 2)
                }
            }
        }
        close(fd)
        guard ok else { try? FileManager.default.removeItem(at: tmp); throw RawError.write(String(cString: strerror(errno))) }
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        guard rename(tmp.path, url.path) == 0 else { try? FileManager.default.removeItem(at: tmp); throw RawError.write(String(cString: strerror(errno))) }
        return cursor
    }

    static func exifDate(_ d: Date) -> String {
        var t = time_t(d.timeIntervalSince1970); var tmv = tm()
        localtime_r(&t, &tmv)
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday), Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec))
    }

    static func xmp(rating: Int?) -> String {
        let r = rating.map { " xmp:Rating=\"\($0)\"" } ?? ""
        return "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:CreatorTool=\"mSIZER\"\(r)/></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
    }
}

// MARK: - JPEG sans perte (ITU T.81, prédicteur 1, 16 bits, deux composantes entrelacées pour les capteurs à matrice)

enum LJPEG {
    /// Une tuile = un flux JPEG complet (tuiles de 256 × 256 comme Adobe : lues par tous les logiciels) ; table de Huffman optimale commune.
    static func encodeTiles(pix: UnsafePointer<UInt16>, stride: Int, width: Int, height: Int, tile: Int) -> [Data] {
        let comps = 2                                    // la largeur des tuiles est paire
        let table = HuffTable(hist: histogram(pix: pix, stride: stride, width: width, height: height, comps: comps))
        let nx = (width + tile - 1) / tile, ny = (height + tile - 1) / tile
        var out = [Data](repeating: Data(), count: nx * ny)
        out.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: nx * ny) { i in
                let tx = i % nx, ty = i / nx
                let x0 = tx * tile, y0 = ty * tile
                if x0 + tile <= width && y0 + tile <= height {
                    p[i] = strip(pix: pix + y0 * stride + x0, stride: stride, width: tile, nrows: tile, comps: comps, table: table)
                } else {
                    // Tuile de bord : complétée en répétant le dernier pixel valide.
                    var pad = [UInt16](repeating: 0, count: tile * tile)
                    for r in 0..<tile {
                        let sr = min(y0 + r, height - 1)
                        for c in 0..<tile { pad[r * tile + c] = pix[sr * stride + min(x0 + c, width - 1)] }
                    }
                    p[i] = pad.withUnsafeBufferPointer { strip(pix: $0.baseAddress!, stride: tile, width: tile, nrows: tile, comps: comps, table: table) }
                }
            }
        }
        return out
    }

    @inline(__always) private static func category(_ d: Int32) -> Int {
        let a = d < 0 ? -d : d
        return a == 0 ? 0 : 32 - a.leadingZeroBitCount
    }

    /// Histogramme des catégories de différences (une rangée sur quatre : suffisant pour une table optimale).
    static func histogram(pix: UnsafePointer<UInt16>, stride: Int, width: Int, height: Int, comps: Int) -> [Int] {
        var hist = [Int](repeating: 0, count: 17)
        let spl = width / comps
        var r = 1
        while r < height {
            let row = pix + r * stride, above = pix + (r - 1) * stride
            for c in 0..<comps {
                let d = Int32(Int16(truncatingIfNeeded: Int32(row[c]) &- Int32(above[c])))
                hist[category(d)] += 1
            }
            if spl > 1 {
                for i in comps..<(spl * comps) {
                    let d = Int32(Int16(truncatingIfNeeded: Int32(row[i]) &- Int32(row[i - comps])))
                    hist[category(d)] += 1
                }
            }
            r += 4
        }
        return hist
    }

    struct HuffTable {
        var bits = [UInt8](repeating: 0, count: 17)   // [1…16]
        var vals: [UInt8] = []
        var code = [UInt32](repeating: 0, count: 17)
        var len = [Int](repeating: 0, count: 17)

        init(hist: [Int]) {
            // Algorithme K.2 de T.81 (comme libjpeg) : longueurs optimales limitées à 16 bits.
            let n = 18                                   // 17 catégories + code réservé
            var freq = hist.map { $0 + 1 } + [1]
            var size = [Int](repeating: 0, count: n), others = [Int](repeating: -1, count: n)
            while true {
                var c1 = -1, v = Int.max
                for i in 0..<n where freq[i] > 0 && freq[i] <= v { v = freq[i]; c1 = i }
                var c2 = -1; v = Int.max
                for i in 0..<n where freq[i] > 0 && freq[i] <= v && i != c1 { v = freq[i]; c2 = i }
                if c2 < 0 { break }
                freq[c1] += freq[c2]; freq[c2] = 0
                size[c1] += 1
                while others[c1] >= 0 { c1 = others[c1]; size[c1] += 1 }
                others[c1] = c2
                size[c2] += 1
                while others[c2] >= 0 { c2 = others[c2]; size[c2] += 1 }
            }
            var cnt = [Int](repeating: 0, count: 33)
            for i in 0..<n where size[i] > 0 { cnt[min(size[i], 32)] += 1 }
            var i = 32
            while i > 16 {
                while cnt[i] > 0 {
                    var j = i - 2
                    while cnt[j] == 0 { j -= 1 }
                    cnt[i] -= 2; cnt[i - 1] += 1; cnt[j + 1] += 2; cnt[j] -= 1
                }
                i -= 1
            }
            while cnt[i] == 0 { i -= 1 }
            cnt[i] -= 1                                  // retire le code réservé
            for l in 1...16 { bits[l] = UInt8(cnt[l]) }
            for l in 1...32 { for s in 0..<17 where size[s] == l { vals.append(UInt8(s)) } }
            // Codes canoniques.
            var c: UInt32 = 0, k = 0
            for l in 1...16 {
                for _ in 0..<Int(bits[l]) { code[Int(vals[k])] = c; len[Int(vals[k])] = l; c += 1; k += 1 }
                c <<= 1
            }
        }
    }

    private static func strip(pix: UnsafePointer<UInt16>, stride: Int, width: Int, nrows: Int, comps: Int, table: HuffTable) -> Data {
        let spl = width / comps
        let rows = 0..<nrows
        // En-tête : SOI, DHT, SOF3, SOS.
        var head: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC4]
        let nv = table.vals.count
        head += [UInt8((19 + nv) >> 8), UInt8((19 + nv) & 0xFF), 0x00]
        head += table.bits[1...16] + table.vals
        head += [0xFF, 0xC3, 0x00, UInt8(8 + 3 * comps), 16, UInt8(nrows >> 8), UInt8(nrows & 0xFF), UInt8(spl >> 8), UInt8(spl & 0xFF), UInt8(comps)]
        for c in 0..<comps { head += [UInt8(c + 1), 0x11, 0x00] }
        head += [0xFF, 0xDA, 0x00, UInt8(6 + 2 * comps), UInt8(comps)]
        for c in 0..<comps { head += [UInt8(c + 1), 0x00] }
        head += [1, 0, 0]

        var cap = nrows * width * 2 + 4096
        var out = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        var pos = 0
        var acc: UInt64 = 0, nb = 0
        let hc = table.code, hl = table.len

        @inline(__always) func emit(_ s: UInt16, _ pred: UInt16) {
            let d = Int32(Int16(truncatingIfNeeded: Int32(s) &- Int32(pred)))
            let cat = category(d)
            let extra = cat == 16 ? 0 : cat
            let v = UInt32(bitPattern: d >= 0 ? d : d - 1) & ((1 << UInt32(extra)) - 1)
            let l = hl[cat] + extra
            acc = (acc << UInt64(l)) | UInt64((hc[cat] << UInt32(extra)) | v)
            nb += l
            while nb >= 8 {
                let b = UInt8(truncatingIfNeeded: acc >> UInt64(nb - 8))
                out[pos] = b; pos += 1
                if b == 0xFF { out[pos] = 0; pos += 1 }
                nb -= 8
            }
        }

        for r in rows {
            if pos + width * 8 + 64 > cap {
                let ncap = cap * 2 + width * 8
                let o2 = UnsafeMutablePointer<UInt8>.allocate(capacity: ncap)
                o2.update(from: out, count: pos); out.deallocate(); out = o2; cap = ncap
            }
            let row = pix + r * stride
            for c in 0..<comps { emit(row[c], r == rows.lowerBound ? 32768 : (row - stride)[c]) }
            if spl > 1 {
                var i = comps
                let end = spl * comps
                while i < end { emit(row[i], row[i - comps]); i += 1 }
            }
        }
        if nb > 0 {                                      // remplissage final par des 1
            let b = UInt8(truncatingIfNeeded: (acc << UInt64(8 - nb)) | UInt64((1 << (8 - nb)) - 1))
            out[pos] = b; pos += 1
            if b == 0xFF { out[pos] = 0; pos += 1 }
        }
        out[pos] = 0xFF; out[pos + 1] = 0xD9; pos += 2
        var d = Data(capacity: head.count + pos)
        d.append(contentsOf: head)
        d.append(out, count: pos)
        out.deallocate()
        return d
    }
}

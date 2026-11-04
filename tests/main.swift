// Tests de logique : géométrie, traitement réel de bout en bout, limite de poids, traductions.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var failures = 0
func check(_ ok: Bool, _ msg: String, line: Int = #line) { if !ok { failures += 1; print("ÉCHEC (l.\(line)) : \(msg)") } }

// --- Géométrie
var s = Settings()
var p = Engine.plan(width: 4000, height: 3000, s)
check(p.outW == 1920 && p.outH == 1440, "grand côté 1920 : \(p.outW)×\(p.outH)")
s.noEnlarge = true; s.resizeValue = 8000
p = Engine.plan(width: 4000, height: 3000, s); check(p.outW == 4000, "pas d'agrandissement")
s.noEnlarge = false; p = Engine.plan(width: 4000, height: 3000, s); check(p.outW == 8000 && p.outH == 6000, "agrandissement permis")
s = Settings(); s.resizeMode = .percent; s.resizeValue = 50
p = Engine.plan(width: 4000, height: 3000, s); check(p.outW == 2000 && p.outH == 1500, "50 %")
s = Settings(); s.resizeMode = .fit; s.resizeValue = 1000; s.resizeValue2 = 1000
p = Engine.plan(width: 4000, height: 3000, s); check(p.outW == 1000 && p.outH == 750, "dans un cadre")
s.resizeMode = .fill
p = Engine.plan(width: 4000, height: 3000, s); check(p.outW == 1000 && p.outH == 1000 && p.finalCrop != nil, "remplir : \(p.outW)×\(p.outH)")
s = Settings(); s.cropOn = true; s.cropRatio = .square; s.resizeOn = false
p = Engine.plan(width: 4000, height: 3000, s); check(p.outW == 3000 && p.outH == 3000 && p.crop.minX == 500, "recadrage 1:1 centré")
s.cropAnchor = .topLeft; p = Engine.plan(width: 4000, height: 3000, s); check(p.crop.minX == 0, "recadrage ancré à gauche")
s = Settings(); s.rotateOn = true; s.rotation = .cw
p = Engine.plan(width: 4000, height: 3000, s); check(p.rotatedW == 3000 && p.outH == 1920, "rotation 90° échange les côtés : \(p.outW)×\(p.outH)")
s = Settings(); s.resizeOn = false
// --- Recadrage manuel
s = Settings(); s.resizeOn = false; s.cropOn = true; s.cropRatio = .manual; s.cropRect = NormRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4)
p = Engine.plan(width: 4000, height: 3000, s)
check(p.crop == CGRect(x: 1000, y: 300, width: 2000, height: 1200) && p.outW == 2000 && p.outH == 1200, "cadre libre : \(p.crop)")
s.cropLock = .square; p = Engine.plan(width: 4000, height: 3000, s)
check(p.outW == p.outH && p.outW == 1200 && p.crop.midX == 2000, "cadre verrouillé 1:1 : \(p.crop)")
s.cropRect = NormRect(); s.cropLock = .r169; p = Engine.plan(width: 3000, height: 4000, s)
check(p.outW == 3000 && p.outH == 1688, "16:9 dans une photo portrait : \(p.outW)×\(p.outH)")
var nr = NormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4).resized(.br, to: CGPoint(x: 5, y: 5), lock: nil, aspect: 4.0 / 3)
check(nr.x == 0.2 && nr.y == 0.2 && nr.w == 0.8 && nr.h == 0.8, "poignée libre bornée à l'image : \(nr)")
nr = NormRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4).resized(.l, to: CGPoint(x: 0.9, y: 0.5), lock: nil, aspect: 1)
check(abs(nr.w - NormRect.minSize) < 1e-9 && abs(nr.x + nr.w - 0.6) < 1e-9, "poignée ne franchit pas le bord opposé : \(nr)")
nr = NormRect(x: 0.3, y: 0.3, w: 0.2, h: 0.2).resized(.br, to: CGPoint(x: 0.9, y: 0.6), lock: 1, aspect: 1.5)
check(abs(nr.w * 1.5 / nr.h - 1) < 1e-9 && nr.x + nr.w <= 1 && nr.y + nr.h <= 1, "poignée verrouillée garde le rapport : \(nr)")
nr = NormRect.corner(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.1, y: 0.9), lock: nil, aspect: 1)
check(abs(nr.x - 0.1) < 1e-9 && abs(nr.y - 0.5) < 1e-9 && abs(nr.w - 0.4) < 1e-9 && abs(nr.h - 0.4) < 1e-9, "tracé d'un nouveau cadre vers le bas-gauche : \(nr)")
nr = NormRect(x: 0.7, y: 0.7, w: 0.2, h: 0.2).moved(dx: 0.5, dy: -2)
check(nr.x == 0.8 && nr.y == 0, "déplacement borné : \(nr)")

// --- Réseaux sociaux : taille exacte pour toute photo
for net in Social.networks {
    for sp in net.specs {
        for (w, h) in [(4000, 3000), (3000, 4000), (1500, 1500), (800, 600)] {
            let q = Engine.plan(width: w, height: h, Social.settings(sp))
            check(q.outW == sp.w && q.outH == sp.h, "\(net.name) \(sp.kind) pour \(w)×\(h) : \(q.outW)×\(q.outH)")
        }
    }
}

s = Settings(); s.resizeOn = false
p = Engine.plan(width: 123, height: 77, s); check(p.outW == 123 && p.outH == 77, "sans opération, taille intacte")

// --- Noms
s = Settings(); s.renameOn = true; s.pattern = "{name}-{n}-{w}x{h}"; s.startNumber = 7
check(Engine.fileStem(for: URL(fileURLWithPath: "/a/IMG.jpg"), index: 2, w: 10, h: 20, s) == "IMG-009-10x20", "modèle de nom")
s.pattern = "a/b"; check(Engine.fileStem(for: URL(fileURLWithPath: "/a/IMG.jpg"), index: 0, w: 1, h: 1, s) == "a-b", "barre remplacée")

// --- Réglages anciens / incomplets
let old = try! JSONSerialization.data(withJSONObject: ["quality": 0.5, "inconnu": 1])
check(Settings.decodeLenient(old)?.quality == 0.5 && Settings.decodeLenient(old)?.resizeValue == 1920, "relecture tolérante")

// --- Traitement réel
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("msizer-test-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
func makeImage(_ url: URL, _ w: Int, _ h: Int) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<400 {
        ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: .random(in: 0...1, using: &rng), alpha: 1))
        ctx.fill(CGRect(x: .random(in: 0...Double(w), using: &rng), y: .random(in: 0...Double(h), using: &rng), width: Double.random(in: 20...400, using: &rng), height: Double.random(in: 20...400, using: &rng)))
    }
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    CGImageDestinationFinalize(d)
}
func size(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let pr = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
    return (pr[kCGImagePropertyPixelWidth as String] as! Int, pr[kCGImagePropertyPixelHeight as String] as! Int)
}
let src = tmp.appendingPathComponent("photo.jpg")
makeImage(src, 3000, 2000)

s = Settings(); s.outputMode = .folder; s.outputFolder = tmp.appendingPathComponent("out").path
var r = Engine.process(src, index: 0, s, Engine.prepare(s))
check(r.error == nil, "traitement de base : \(r.error ?? "")")
if let u = r.url { check(size(u)! == (1920, 1280), "dimensions 1920×1280 : \(size(u)!)") }
r = Engine.process(src, index: 0, s, Engine.prepare(s))
check(r.url?.lastPathComponent == "photo-1.jpg", "jamais d'écrasement : \(r.url?.lastPathComponent ?? "-")")

s.cropOn = true; s.cropRatio = .square; s.resizeMode = .width; s.resizeValue = 800; s.format = .png
r = Engine.process(src, index: 0, s, Engine.prepare(s))
check(r.error == nil && r.url?.pathExtension == "png" && size(r.url!)! == (800, 800), "recadrage + PNG : \(String(describing: r.url.flatMap(size)))")

s = Settings(); s.outputMode = .folder; s.outputFolder = tmp.appendingPathComponent("out2").path
s.adjustOn = true; s.autoEnhance = true; s.sharpen = 0.5; s.saturation = 1.2; s.watermarkOn = true; s.wmText = "© Test"; s.format = .heic
r = Engine.process(src, index: 0, s, Engine.prepare(s))
check(r.error == nil && r.url?.pathExtension == "heic", "retouches + filigrane + HEIC : \(r.error ?? "")")

s = Settings(); s.outputMode = .folder; s.outputFolder = tmp.appendingPathComponent("out3").path; s.resizeOn = false; s.maxKB = 400
r = Engine.process(src, index: 0, s, Engine.prepare(s))
check(r.error == nil && r.bytesOut <= 400_000 && r.bytesOut > 200_000, "limite de poids 400 Ko : \(r.bytesOut) o")

s = Settings(); s.outputMode = .folder; s.outputFolder = tmp.appendingPathComponent("out4").path
s.rotateOn = true; s.rotation = .cw; s.resizeOn = false
r = Engine.process(src, index: 0, s, Engine.prepare(s))
check(r.url.flatMap(size).map { $0 == (2000, 3000) } ?? false, "rotation 90°")

// --- Traductions : mêmes clés dans les quatre langues
let fr = Set(L.tables["fr"]!.keys)
for lang in ["en", "es", "it"] {
    let k = Set(L.tables[lang]!.keys)
    check(k == fr, "\(lang) : clés manquantes \(fr.subtracting(k).sorted()) en trop \(k.subtracting(fr).sorted())")
}
for (lang, t) in L.tables { for (k, v) in t where v.isEmpty { check(false, "\(lang).\(k) vide") } }

try? FileManager.default.removeItem(at: tmp)
if failures == 0 { print("Tous les tests passent.") } else { print("\(failures) échec(s)."); exit(1) }

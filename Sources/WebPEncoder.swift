// mSIZER — encodage WebP avec libwebp (ImageIO sait lire le WebP, pas l'écrire).
import Foundation
import CoreGraphics

enum WebPEncoder {
    /// Dimension maximale d'un fichier WebP.
    static let maxSide = 16383

    /// `quality` de 0 à 1 ; 1 donne du WebP sans perte. L'image est convertie en sRGB, la couleur n'étant pas incorporée au fichier.
    static func encode(_ cg: CGImage, quality: Double) -> Data? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, w <= maxSide, h <= maxSide else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // libwebp attend des couleurs non prémultipliées.
        var i = 0
        while i < px.count {
            let a = Int(px[i + 3])
            if a != 255 && a != 0 {
                px[i] = UInt8(min(255, Int(px[i]) * 255 / a)); px[i + 1] = UInt8(min(255, Int(px[i + 1]) * 255 / a)); px[i + 2] = UInt8(min(255, Int(px[i + 2]) * 255 / a))
            }
            i += 4
        }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { return nil }
        let lossless = quality >= 0.999
        config.quality = lossless ? 75 : Float(quality * 100)
        config.lossless = lossless ? 1 : 0
        config.method = 4
        guard WebPValidateConfig(&config) != 0 else { return nil }

        var pic = WebPPicture()
        guard WebPPictureInit(&pic) != 0 else { return nil }
        pic.width = Int32(w); pic.height = Int32(h)
        pic.use_argb = lossless ? 1 : 0
        defer { WebPPictureFree(&pic) }
        let imported = px.withUnsafeBufferPointer { WebPPictureImportRGBA(&pic, $0.baseAddress, Int32(w * 4)) }
        guard imported != 0 else { return nil }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let ok: Bool = withUnsafeMutablePointer(to: &writer) { wp in
            pic.writer = WebPMemoryWrite
            pic.custom_ptr = UnsafeMutableRawPointer(wp)
            return WebPEncode(&config, &pic) != 0
        }
        guard ok, let mem = writer.mem else { return nil }
        return Data(bytes: mem, count: writer.size)
    }
}

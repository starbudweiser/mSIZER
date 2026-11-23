// mSIZER — détection du sujet et des visages (Vision, sur le GPU / Neural Engine) : suppression de l'arrière-plan, recadrage sur le visage.
import Foundation
import CoreImage
import Vision

enum Subject {
    /// Au plus deux analyses Vision en même temps : le Neural Engine est partagé entre les photos traitées en parallèle.
    private static let gate = DispatchSemaphore(value: 2)
    /// Les modèles travaillent sur une image réduite : inutile de leur donner plus.
    private static let analysisSide: CGFloat = 1536

    private static func reduced(_ ci: CIImage) -> CIImage {
        let side = max(ci.extent.width, ci.extent.height)
        guard side > analysisSide else { return ci }
        let k = analysisSide / side
        return Engine.origin(ci.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1]))
    }

    /// Plus grand visage, en fractions de l'image (origine en haut à gauche).
    static func face(in ci: CIImage) -> CGRect? {
        gate.wait(); defer { gate.signal() }
        let handler = VNImageRequestHandler(ciImage: reduced(ci), options: [.ciContext: Engine.context])
        let req = VNDetectFaceRectanglesRequest()
        guard (try? handler.perform([req])) != nil, let best = req.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let b = best.boundingBox
        return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }

    /// Masque du ou des sujets au premier plan : niveaux de gris, de la taille de l'image (blanc = sujet), nil si rien n'est détecté.
    static func mask(for ci: CIImage) -> CIImage? {
        gate.wait(); defer { gate.signal() }
        let small = reduced(ci)
        let handler = VNImageRequestHandler(ciImage: small, options: [.ciContext: Engine.context])
        let req = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first, !obs.allInstances.isEmpty,
              let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }
        var m = CIImage(cvPixelBuffer: buf, options: [.colorSpace: NSNull()])
        let bounds = m.extent
        m = m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: bounds)
        m = Engine.origin(m)
        if Int(m.extent.width) != Int(ci.extent.width) || Int(m.extent.height) != Int(ci.extent.height) {
            m = Engine.scaled(m, toW: Int(ci.extent.width), h: Int(ci.extent.height))
        }
        return m
    }

    /// Détoure l'image avec le masque : contraction puis adoucissement des bords, puis fond choisi (ou flou de l'image elle-même).
    static func composite(_ ci: CIImage, mask: CIImage, _ s: Settings) -> CIImage {
        let ext = ci.extent
        let u = max(ext.width, ext.height) / 1000          // unité des réglages : px pour une image de 1000 px de côté
        var m = mask
        if s.bgShrink > 0 { m = m.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: s.bgShrink * u]).cropped(to: ext) }
        if s.bgFeather > 0 { m = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: s.bgFeather * u]).cropped(to: ext) }
        let bg: CIImage
        switch s.bgFill {
        case .transparent: bg = CIImage(color: .clear)
        case .white: bg = CIImage(color: .white)
        case .black: bg = CIImage(color: .black)
        case .color: bg = CIImage(color: CIColor(red: s.bgR, green: s.bgG, blue: s.bgB))
        case .blur: bg = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: (2 + s.bgBlur * 20) * u])
        }
        return ci.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg.cropped(to: ext), kCIInputMaskImageKey: m]).cropped(to: ext)
    }
}

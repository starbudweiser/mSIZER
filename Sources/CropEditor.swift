// mSIZER — recadrage manuel : cadre à poignées libres posé sur l'onglet « Avant » de l'aperçu.
import SwiftUI

struct CropOverlay: View {
    @ObservedObject var store = Store.shared
    /// Marge autour de l'image où les poignées restent attrapables.
    static let inset: CGFloat = 18
    private let grab: CGFloat = 14

    private enum Mode { case move(NormRect), resize(CropHandle, NormRect), draw(CGPoint) }
    @State private var mode: Mode?
    @State private var live: NormRect?

    private typealias CropHandle = NormRect.Handle

    var body: some View {
        GeometryReader { geo in
            let iw = max(1, geo.size.width - 2 * Self.inset), ih = max(1, geo.size.height - 2 * Self.inset)
            let aspect = Double(iw / ih)
            let r = live ?? store.currentCrop
            let rect = frame(r, iw, ih)
            ZStack(alignment: .topLeading) {
                Path { p in p.addRect(CGRect(x: 0, y: 0, width: iw, height: ih)); p.addRect(rect) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                Path { p in
                    for i in 1...2 {
                        let fx = rect.minX + rect.width * CGFloat(i) / 3, fy = rect.minY + rect.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: fx, y: rect.minY)); p.addLine(to: CGPoint(x: fx, y: rect.maxY))
                        p.move(to: CGPoint(x: rect.minX, y: fy)); p.addLine(to: CGPoint(x: rect.maxX, y: fy))
                    }
                }.stroke(Color.white.opacity(0.35), lineWidth: 0.5).allowsHitTesting(false)
                Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY).allowsHitTesting(false)
                ForEach(CropHandle.allCases, id: \.self) { h in
                    let c = point(h, rect)
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .offset(x: c.x - 5, y: c.y - 5).allowsHitTesting(false)
                }
                if let (pw, ph) = pixels(r) {
                    Text("\(pw) × \(ph)").socle(Socle.T.monoSm).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: rect.minX + 6, y: max(2, rect.minY + 6)).allowsHitTesting(false)
                }
            }
            .frame(width: iw, height: ih, alignment: .topLeading)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in drag(v, iw, ih, aspect) }
                        .onEnded { _ in
                            if let l = live { store.setCrop(l) }
                            live = nil; mode = nil
                        })
            }
        }
    }

    private func frame(_ r: NormRect, _ iw: CGFloat, _ ih: CGFloat) -> CGRect {
        CGRect(x: r.x * iw, y: r.y * ih, width: r.w * iw, height: r.h * ih)
    }

    private func point(_ h: CropHandle, _ r: CGRect) -> CGPoint {
        CGPoint(x: h.left ? r.minX : h.right ? r.maxX : r.midX, y: h.top ? r.minY : h.bottom ? r.maxY : r.midY)
    }

    /// Taille en pixels de la zone conservée, d'après la photo choisie.
    private func pixels(_ r: NormRect) -> (Int, Int)? {
        guard let it = store.selectedItem, it.width > 0, it.height > 0 else { return nil }
        let s = store.settings
        let plan = Engine.plan(width: it.width, height: it.height, { var c = s; c.cropRect = r; return c }())
        return (Int(plan.crop.width), Int(plan.crop.height))
    }

    private func drag(_ v: DragGesture.Value, _ iw: CGFloat, _ ih: CGFloat, _ aspect: Double) {
        let lock = store.settings.lockRatio
        // Coordonnées locales du geste : l'image commence à `inset`.
        func norm(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - Self.inset) / iw, y: (p.y - Self.inset) / ih) }
        if mode == nil {
            let start = store.currentCrop
            let rect = frame(start, iw, ih).offsetBy(dx: Self.inset, dy: Self.inset)
            let hit = CropHandle.allCases.first { h in
                let c = point(h, rect); return abs(c.x - v.startLocation.x) <= grab && abs(c.y - v.startLocation.y) <= grab
            }
            if let hit { mode = .resize(hit, start) }
            else if rect.contains(v.startLocation) { mode = .move(start) }
            else { mode = .draw(norm(v.startLocation)) }
        }
        let p = norm(v.location)
        switch mode {
        case .resize(let h, let start): live = start.resized(h, to: p, lock: lock, aspect: aspect)
        case .move(let start): live = start.moved(dx: Double(v.translation.width / iw), dy: Double(v.translation.height / ih))
        case .draw(let a): live = NormRect.corner(from: a, to: p, lock: lock, aspect: aspect)
        case nil: break
        }
    }
}

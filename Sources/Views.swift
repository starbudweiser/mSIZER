// mSIZER — interface SwiftUI (design system Socle).
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Brand {
    /// Rose du logo : la lettre « m » de mSIZER.
    static let color = Color(red: 0xf4 / 255, green: 0x72 / 255, blue: 0xb6 / 255)
}

/// Motif de l'icône (cadre, petit carré et flèche de redimensionnement), d'une seule teinte : logo, filigrane, état vide.
/// Même géométrie que Resources/make_icon.swift (repère mathématique, y vers le haut, unités de l'icône 1024).
struct MsizerMark: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 640
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * k, y: c.y - y * k) }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: c.x + x * k, y: c.y - (y + h) * k, width: w * k, height: h * k) }
            ctx.stroke(Path(roundedRect: rect(-250, -250, 500, 500), cornerRadius: 80 * k), with: .foreground, lineWidth: 50 * k)
            ctx.fill(Path(roundedRect: rect(-185, -185, 230, 230), cornerRadius: 30 * k), with: .foreground)
            var line = Path(); line.move(to: pt(45, 45)); line.addLine(to: pt(165, 165))
            ctx.stroke(line, with: .foreground, lineWidth: 44 * k)
            var head = Path()
            head.move(to: pt(215, 215)); head.addLine(to: pt(215, 120)); head.addLine(to: pt(120, 215)); head.closeSubpath()
            ctx.fill(head, with: .foreground)
        }
    }
}

// MARK: - Briques Socle

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(branded: text).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true) }
}

struct Check: View {
    let title: String
    var help: String?
    @Binding var isOn: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $isOn) { Text(title).socle(Socle.T.body).foregroundStyle(Socle.C.text).fixedSize(horizontal: false, vertical: true) }
                .toggleStyle(.checkbox).tint(Socle.C.accent)
            if let help { Hint(help).padding(.leading, 22) }
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Socle.C.bgSunken)
                Rectangle().fill(Socle.C.accent).frame(width: g.size.width * min(1, max(0, value)))
            }
        }.frame(height: 6).clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Bouton carré à icône seule : aplat `control`, un cran plus clair au survol.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(Socle.C.textStrong)
                .frame(width: Socle.M.sizeControl, height: Socle.M.sizeControl)
                .background(configuration.isPressed ? Socle.C.controlPressed : hover ? Socle.C.controlHover : Socle.C.control,
                            in: RoundedRectangle(cornerRadius: Socle.M.radius))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.15), value: hover)
        }
    }
}

/// Grille de choix : l'option retenue prend l'aplat d'accent, les autres restent neutres.
struct ChoiceGrid<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var minWidth: CGFloat = 84

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { selection = o } label: {
                    Text(label(o)).socle(Socle.T.label).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(on ? Socle.C.onAccentFill : Socle.C.text)
                        .background(on ? Socle.C.accentFill : Socle.C.control, in: RoundedRectangle(cornerRadius: Socle.M.radius))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

/// Neuf cases pour choisir une position (zone conservée, emplacement du filigrane).
struct AnchorPicker: View {
    @Binding var selection: Anchor
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { c in
                        let a = Anchor(rawValue: r * 3 + c)!
                        Button { selection = a } label: {
                            RoundedRectangle(cornerRadius: 2).fill(a == selection ? Socle.C.accent : Socle.C.control)
                                .frame(width: 22, height: 16)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var display: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                Spacer()
                Text(display(value)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.accentText)
            }
            Slider(value: $value, in: range).tint(Socle.C.accent)
        }
    }
}

struct NumberRow: View {
    let title: String
    @Binding var value: Double
    var unit: String?
    var body: some View {
        HStack(spacing: Socle.M.space2) {
            Text(title).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
            Spacer()
            TextField("", value: $value, format: .number.grouping(.never)).multilineTextAlignment(.trailing)
                .socle(Socle.T.mono).socleValue().socleField().frame(width: 96)
            if let unit { Text(unit).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).frame(width: 24, alignment: .leading) }
        }
    }
}

/// Carte d'une opération : en-tête avec case d'activation, contenu visible seulement quand l'opération est active.
struct OpCard<Content: View>: View {
    let title: String
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    private var active: Bool { isOn?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            if let isOn {
                Toggle(isOn: isOn) { Text(title).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong) }
                    .toggleStyle(.checkbox).tint(Socle.C.accent)
            } else {
                Text(title).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            }
            if active { content }
        }
        .padding(Socle.M.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusLg).stroke(Socle.C.border, lineWidth: 1))
        .opacity(active ? 1 : 0.7)
    }
}

// MARK: - Fenêtre principale

struct ContentView: View {
    @ObservedObject var store = Store.shared
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Socle.M.space3) {
                Text(branded: "mSIZER").socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                Spacer()
                Button { store.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)) }
                    .buttonStyle(IconButtonStyle()).help(L.t("menu.settings")).accessibilityLabel(L.t("menu.settings"))
            }
            .padding(.horizontal, Socle.M.space3).frame(height: Socle.M.sizeBar)
            .background(Socle.C.surfaceRaised)
            Rectangle().fill(Socle.C.border).frame(height: 1)
            HStack(spacing: 0) {
                SettingsPanel().frame(width: 380)
                Rectangle().fill(Socle.C.border).frame(width: 1)
                if store.items.isEmpty {
                    EmptyState().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ListPanel().frame(width: 300)
                    Rectangle().fill(Socle.C.border).frame(width: 1)
                    PreviewPanel().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Rectangle().fill(Socle.C.border).frame(height: 1)
            BottomBar()
        }
        .background(Socle.C.bg)
        .frame(minWidth: 1180, minHeight: 720)
        .environment(\.locale, L.locale)
        .background(WindowSetup())
        .overlay { if dropping { RoundedRectangle(cornerRadius: Socle.M.radiusLg).stroke(Socle.C.accent, lineWidth: 2).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in Store.shared.add([url]) } }
                }
            }
            return true
        }
        .sheet(isPresented: $store.showSettings) { SettingsSheet() }
    }
}

/// Centre la fenêtre à l'ouverture (écran du pointeur) et applique le thème.
struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
            if let zone = screen?.visibleFrame {
                w.setContentSize(NSSize(width: min(1500, zone.width - 40), height: zone.height - 60))
            }
            w.socleCenter(); w.makeKeyAndOrderFront(nil)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Store {
    func pickFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK { add(p.urls) }
    }

    func pickFolder(start: String, _ done: (String) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if !start.isEmpty { p.directoryURL = URL(fileURLWithPath: start) }
        if p.runModal() == .OK, let u = p.url { done(u.path) }
    }
}

struct EmptyState: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        VStack(spacing: Socle.M.space4) {
            MsizerMark().frame(width: 96, height: 96).foregroundStyle(Brand.color)
            Text(L.t("empty.title")).socle(Socle.T.display).foregroundStyle(Socle.C.textStrong)
            Text(branded: L.t("empty.body")).socle(Socle.T.reading).foregroundStyle(Socle.C.textMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Button(L.t("btn.add")) { store.pickFiles() }.buttonStyle(SocleButtonStyle(.action)).frame(width: 220)
        }
        .padding(Socle.M.space8)
        .frame(maxWidth: 560)
        .padding(Socle.M.space6)
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusLg).stroke(Socle.C.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [6, 4])).padding(28))
    }
}

// MARK: - Liste

struct ListPanel: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Socle.M.space2) {
                Text(L.photos(store.items.count)).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
                Spacer()
                Button(L.t("btn.clear")) { store.clear() }.buttonStyle(SocleButtonStyle(.tertiary, height: Socle.M.sizeControl)).fixedSize()
                    .disabled(store.processing)
            }
            .padding(.horizontal, Socle.M.space3).padding(.vertical, Socle.M.space2)
            Rectangle().fill(Socle.C.border).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { PhotoRow(item: $0) }
                }
            }
            Rectangle().fill(Socle.C.border).frame(height: 1)
            Button(L.t("btn.add")) { store.pickFiles() }.buttonStyle(SocleButtonStyle(.secondary)).padding(Socle.M.space3)
        }
        .background(Socle.C.surfaceRaised)
    }
}

struct PhotoRow: View {
    let item: PhotoItem
    @ObservedObject var store = Store.shared
    @State private var hover = false

    var body: some View {
        let selected = store.selection == item.id
        HStack(spacing: Socle.M.space2_5) {
            Group {
                if let t = item.thumb { Image(nsImage: t).resizable().scaledToFill() } else { Socle.C.bgSunken }
            }
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: Socle.M.radius))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).socle(Socle.T.body).foregroundStyle(selected ? Socle.C.textStrong : Socle.C.text).lineLimit(1).truncationMode(.middle)
                Text("\(item.width) × \(item.height) · \(Format.bytes(item.bytes))").socle(Socle.T.monoSm).foregroundStyle(Socle.C.textSubtle).lineLimit(1)
                switch item.status {
                case .pending: EmptyView()
                case .done(let b): Text("✓ \(L.t("st.done")) · \(Format.bytes(b))").socle(Socle.T.meta).foregroundStyle(Socle.C.success).lineLimit(1)
                case .failed(let e): Text("✕ \(e)").socle(Socle.T.meta).foregroundStyle(Socle.C.danger).lineLimit(1).help(e)
                }
            }
            Spacer(minLength: 0)
            if hover && !store.processing {
                Button { store.remove(item.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Socle.C.textMuted)
            }
        }
        .padding(.horizontal, Socle.M.space3).padding(.vertical, 6)
        .background(selected ? Socle.C.surfaceSelected : hover ? Socle.C.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selection = item.id }
        .onHover { hover = $0 }
    }
}

// MARK: - Aperçu

struct PreviewPanel: View {
    @ObservedObject var store = Store.shared
    @State private var showAfter = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Socle.M.space3) {
                SocleSegmented(options: [false, true], selection: showAfter, label: { $0 ? L.t("pv.after") : L.t("pv.before") },
                               tone: { _ in .strong }) { showAfter = $0 }
                Spacer()
                if !store.previewInfo.isEmpty {
                    Text(L.t("pv.size", store.previewInfo)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.accentText)
                }
            }
            .padding(Socle.M.space3)
            Rectangle().fill(Socle.C.border).frame(height: 1)
            ZStack {
                Socle.C.bgSunken
                if let img = showAfter ? store.previewAfter : store.previewBefore {
                    Image(nsImage: img).resizable().scaledToFit().padding(Socle.M.space6)
                } else if store.selectedItem == nil {
                    Text(L.t("pv.none")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                }
                if store.previewBusy { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(Socle.M.space3) }
            }
        }
    }
}

// MARK: - Réglages de traitement

struct SettingsPanel: View {
    @ObservedObject var store = Store.shared

    var body: some View {
        let s = $store.settings
        ScrollView {
            VStack(spacing: Socle.M.space2) {
                PresetBar()
                OpCard(title: L.t("op.resize"), isOn: s.resizeOn) {
                    ChoiceGrid(options: ResizeMode.allCases, selection: s.resizeMode, label: { L.t("rs." + $0.rawValue) }, minWidth: 100)
                    let m = store.settings.resizeMode
                    if m == .fit || m == .fill {
                        NumberRow(title: L.t("rs.width"), value: s.resizeValue, unit: "px")
                        NumberRow(title: L.t("rs.height"), value: s.resizeValue2, unit: "px")
                        Hint(L.t(m == .fit ? "rs.fit.help" : "rs.fill.help"))
                    } else {
                        NumberRow(title: L.t("rs." + m.rawValue), value: s.resizeValue, unit: m == .percent ? "%" : "px")
                    }
                    Check(title: L.t("rs.noEnlarge"), isOn: s.noEnlarge)
                }
                OpCard(title: L.t("op.crop"), isOn: s.cropOn) {
                    ChoiceGrid(options: CropRatio.allCases, selection: s.cropRatio, label: { $0.label }, minWidth: 64)
                    if store.settings.cropRatio == .custom {
                        HStack {
                            NumberRow(title: "", value: s.cropW)
                            Text(":").foregroundStyle(Socle.C.textMuted)
                            NumberRow(title: "", value: s.cropH)
                        }
                    }
                    HStack {
                        Text(L.t("crop.anchor")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                        Spacer()
                        AnchorPicker(selection: s.cropAnchor)
                    }
                }
                OpCard(title: L.t("op.rotate"), isOn: s.rotateOn) {
                    ChoiceGrid(options: Rotation.allCases, selection: s.rotation,
                               label: { r in r == .none ? "0°" : r == .cw ? "90° ↻" : r == .ccw ? "90° ↺" : "180°" }, minWidth: 64)
                    Check(title: L.t("rot.flipH"), isOn: s.flipH)
                    Check(title: L.t("rot.flipV"), isOn: s.flipV)
                }
                OpCard(title: L.t("op.adjust"), isOn: s.adjustOn) {
                    Check(title: L.t("adj.auto"), isOn: s.autoEnhance)
                    SliderRow(title: L.t("adj.brightness"), value: s.brightness, range: -0.5...0.5) { String(format: "%+.0f", $0 * 100) }
                    SliderRow(title: L.t("adj.contrast"), value: s.contrast, range: 0.5...1.5) { String(format: "%.0f %%", $0 * 100) }
                    SliderRow(title: L.t("adj.saturation"), value: s.saturation, range: 0...2) { String(format: "%.0f %%", $0 * 100) }
                    SliderRow(title: L.t("adj.sharpen"), value: s.sharpen, range: 0...2) { String(format: "%.0f", $0 * 50) }
                    Check(title: L.t("adj.mono"), isOn: s.mono)
                }
                OpCard(title: L.t("op.watermark"), isOn: s.watermarkOn) {
                    ChoiceGrid(options: WatermarkKind.allCases, selection: s.wmKind, label: { L.t("wm." + $0.rawValue) })
                    if store.settings.wmKind == .text {
                        TextField(L.t("wm.placeholder"), text: s.wmText).socle(Socle.T.body).socleField()
                        Check(title: L.t("wm.dark"), isOn: s.wmDark)
                    } else {
                        HStack(spacing: Socle.M.space2) {
                            Text(store.settings.wmImagePath.isEmpty ? L.t("wm.nologo") : URL(fileURLWithPath: store.settings.wmImagePath).lastPathComponent)
                                .socle(Socle.T.mono).foregroundStyle(Socle.C.accentText).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button(L.t("wm.choose")) { pickLogo() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                        }
                    }
                    SliderRow(title: L.t("wm.size"), value: s.wmSize, range: 0.05...0.8) { String(format: "%.0f %%", $0 * 100) }
                    SliderRow(title: L.t("wm.opacity"), value: s.wmOpacity, range: 0.1...1) { String(format: "%.0f %%", $0 * 100) }
                    HStack {
                        Text(L.t("wm.position")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                        Spacer()
                        AnchorPicker(selection: s.wmAnchor)
                    }
                }
                OpCard(title: L.t("op.format"), isOn: nil) {
                    ChoiceGrid(options: OutFormat.allCases, selection: s.format, label: { $0.label }, minWidth: 58)
                    let f = store.settings.format
                    if f != .png && f != .tiff {
                        SliderRow(title: L.t("fmt.quality"), value: s.quality, range: 0.1...1) { String(format: "%.0f %%", $0 * 100) }
                        NumberRow(title: L.t("fmt.maxsize"), value: Binding(get: { Double(store.settings.maxKB) }, set: { store.settings.maxKB = max(0, Int($0)) }))
                        Hint(L.t("fmt.maxsize.help"))
                    }
                    Check(title: L.t("fmt.srgb"), help: L.t("fmt.srgb.help"), isOn: s.toSRGB)
                }
                OpCard(title: L.t("op.meta"), isOn: nil) {
                    ChoiceGrid(options: MetaMode.allCases, selection: s.metaMode, label: { L.t("meta." + ($0 == .stripAll ? "strip" : $0.rawValue)) }, minWidth: 100)
                }
                OpCard(title: L.t("op.rename"), isOn: s.renameOn) {
                    TextField("{name}", text: s.pattern).socle(Socle.T.mono).socleValue().socleField()
                    Hint(L.t("ren.help"))
                    NumberRow(title: L.t("ren.start"), value: Binding(get: { Double(store.settings.startNumber) }, set: { store.settings.startNumber = max(0, Int($0)) }))
                }
                OpCard(title: L.t("op.output"), isOn: nil) {
                    ChoiceGrid(options: OutputMode.allCases, selection: s.outputMode, label: { L.t("out." + $0.rawValue) }, minWidth: 150)
                    switch store.settings.outputMode {
                    case .subfolder: Hint(L.t("out.subfolder.help"))
                    case .folder:
                        HStack(spacing: Socle.M.space2) {
                            Text(store.settings.outputFolder).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                            Button(L.t("btn.choose")) { store.pickFolder(start: store.settings.outputFolder) { store.settings.outputFolder = $0 } }
                                .buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                        }
                    case .replace: Text(L.t("out.replace.help")).socle(Socle.T.meta).foregroundStyle(Socle.C.warning).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Socle.M.space3)
        }
        .background(Socle.C.bg)
    }

    private func pickLogo() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = false; p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { store.settings.wmImagePath = u.path }
    }
}

struct PresetBar: View {
    @ObservedObject var store = Store.shared
    @State private var asking = false
    @State private var newName = ""

    var body: some View {
        OpCard(title: L.t("preset.title"), isOn: nil) {
            Menu {
                ForEach(Store.builtIns) { p in Button(p.name) { store.apply(p.settings) } }
                if !store.presets.isEmpty {
                    Divider()
                    ForEach(store.presets) { p in Button(p.name) { store.apply(p.settings) } }
                    Divider()
                    Menu(L.t("preset.mine")) {
                        ForEach(store.presets) { p in Button(L.t("preset.delete", p.name), role: .destructive) { store.deletePreset(p) } }
                    }
                }
                Divider()
                Button(L.t("preset.save")) { newName = ""; asking = true }
            } label: {
                Text(L.t("preset.pick")).socle(Socle.T.button).foregroundStyle(Socle.C.textStrong)
                    .frame(maxWidth: .infinity, minHeight: Socle.M.sizeControlLg)
                    .background(Socle.C.control, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
        .alert(L.t("preset.name"), isPresented: $asking) {
            TextField(L.t("preset.name"), text: $newName)
            Button(L.t("btn.save")) { store.savePreset(named: newName) }
            Button(L.t("btn.cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Barre du bas

struct BottomBar: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        HStack(spacing: Socle.M.space4) {
            if store.processing {
                ProgressBar(value: store.progress).frame(maxWidth: .infinity)
                Text("\(Int(store.progress * 100)) %").socle(Socle.T.mono).foregroundStyle(Socle.C.accentText)
                Button(L.t("btn.cancel")) { store.cancel() }.buttonStyle(SocleButtonStyle(.secondary)).frame(width: 160)
            } else {
                Text(store.summary ?? "").socle(Socle.T.body)
                    .foregroundStyle(store.summary == nil ? Socle.C.textMuted : (store.summaryWarning ? Socle.C.warning : Socle.C.success))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let f = store.lastOutput {
                    Button(L.t("btn.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([f]) }.buttonStyle(SocleButtonStyle(.secondary)).frame(width: 200)
                }
                Button(L.t("btn.process")) { store.start() }.buttonStyle(SocleButtonStyle(.action)).frame(width: 240)
                    .disabled(store.items.isEmpty)
            }
        }
        .padding(.horizontal, Socle.M.space4).frame(height: 64)
        .background(Socle.C.surfaceRaised)
    }
}

// MARK: - Réglages de l'appli

struct SheetFrame<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(spacing: 0) {
            Text(branded: title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Socle.M.space6)
            Rectangle().fill(Socle.C.border).frame(height: 1)
            content.padding(Socle.M.space6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Socle.C.border).frame(height: 1)
            HStack(spacing: Socle.M.space2) { Spacer(); footer }.padding(Socle.M.space4)
        }
        .background(Socle.C.surface).environment(\.locale, L.locale)
    }
}

struct SettingsSheet: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        SheetFrame(title: L.t("set.title")) {
            VStack(alignment: .leading, spacing: Socle.M.space4) {
                OpCard(title: L.t("upd.title"), isOn: nil) { UpdateSection() }
                Hint(L.t("set.engine", Engine.workers))
                Button(L.t("menu.about")) { About.show() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
            }
        } footer: {
            Button(L.t("btn.close")) { store.showSettings = false }.buttonStyle(SocleButtonStyle(.primary)).frame(width: 130)
        }
        .frame(width: 520, height: 420)
    }
}

struct UpdateSection: View {
    @ObservedObject var updater = Updater.shared
    @AppStorage("autoUpdate") private var auto = true

    private var status: String {
        switch updater.state {
        case .idle: return L.t("upd.version", updater.currentVersion)
        case .checking: return L.t("upd.checking")
        case .upToDate: return L.t("upd.uptodate", updater.currentVersion)
        case .available(let v): return L.t("upd.available", v)
        case .downloading: return L.t("upd.downloading")
        case .failed(let e): return L.t("upd.failed", e)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Check(title: L.t("upd.auto"), isOn: $auto)
            HStack(spacing: Socle.M.space2) {
                Button(L.t("upd.check")) { Task { await updater.check() } }
                    .buttonStyle(SocleButtonStyle(.secondary)).lineLimit(1).frame(width: 220)
                    .disabled(updater.state == .checking || updater.state == .downloading)
                if case .available(let v) = updater.state {
                    Button(L.t("upd.install", v)) { Task { await updater.install() } }
                        .buttonStyle(SocleButtonStyle(.primary)).lineLimit(1).frame(width: 220)
                        .disabled(Store.shared.processing)
                }
            }
            Hint(status)
            if case .available = updater.state, Store.shared.processing { Hint(L.t("upd.busy")) }
        }
    }
}

// Génère l'icône (1024 px) : carré arrondi sombre Socle, cadre rose, petit carré et flèche de redimensionnement.
// Même géométrie que MsizerMark dans Sources/Views.swift (repère y vers le haut, centre en 512,512).
import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: size - 200, height: size - 200), xRadius: 185, yRadius: 185).fill()
let pink = NSColor(srgbRed: 0xf4/255, green: 0x72/255, blue: 0xb6/255, alpha: 1)
let c = NSPoint(x: size / 2, y: size / 2)
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: c.x + x, y: c.y + y, width: w, height: h) }
let frame = NSBezierPath(roundedRect: r(-250, -250, 500, 500), xRadius: 80, yRadius: 80)
frame.lineWidth = 50; pink.setStroke(); frame.stroke()
NSColor(white: 0.9, alpha: 1).setFill()
NSBezierPath(roundedRect: r(-185, -185, 230, 230), xRadius: 30, yRadius: 30).fill()
pink.setStroke(); pink.setFill()
let line = NSBezierPath(); line.move(to: NSPoint(x: c.x + 45, y: c.y + 45)); line.line(to: NSPoint(x: c.x + 165, y: c.y + 165))
line.lineWidth = 44; line.lineCapStyle = .butt; line.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: c.x + 215, y: c.y + 215)); head.line(to: NSPoint(x: c.x + 215, y: c.y + 120)); head.line(to: NSPoint(x: c.x + 120, y: c.y + 215))
head.close(); head.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

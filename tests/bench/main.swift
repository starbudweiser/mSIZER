// Banc d'essai RAW → DNG : rawbench [--raw] [--verify] <sortie> fichiers…
import Foundation
setenv("OMP_NUM_THREADS", "1", 1)
var args = Array(CommandLine.arguments.dropFirst())
var compressed = true, verify = false
while let a = args.first, a.hasPrefix("--") { if a == "--raw" { compressed = false }; if a == "--verify" { verify = true }; args.removeFirst() }
let outDir = URL(fileURLWithPath: args.removeFirst())
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let files = args.map { URL(fileURLWithPath: $0) }
let t0 = Date()
let lock = NSLock()
var total = 0, srcBytes = 0, fails = 0
DispatchQueue.concurrentPerform(iterations: files.count) { i in
    let u = files[i]
    let dst = outDir.appendingPathComponent(u.deletingPathExtension().lastPathComponent + ".dng")
    do {
        var o = RawConvertOptions(); o.compressed = compressed; o.verify = verify
        let b = try RawEngine.convert(u, to: dst, o)
        let sb = ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int) ?? 0
        lock.lock(); total += b; srcBytes += sb; lock.unlock()
    } catch { lock.lock(); fails += 1; print("ÉCHEC", u.lastPathComponent, error.localizedDescription); lock.unlock() }
}
let dt = Date().timeIntervalSince(t0)
print(String(format: "%d fichiers en %.2f s (%.1f fichiers/s) · source %.1f Mo → DNG %.1f Mo · %d échecs", files.count, dt, Double(files.count) / dt, Double(srcBytes) / 1e6, Double(total) / 1e6, fails))

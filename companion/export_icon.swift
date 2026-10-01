import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

struct ListedApp {
    var id: String
    var name: String
    var path: String
    var priority: Int
}

func listApps() -> [[String: String]] {
    let fm = FileManager.default
    var found: [String: ListedApp] = [:]
    let homeApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    let roots: [(URL, Int)] = [
        (URL(fileURLWithPath: "/Applications", isDirectory: true), 0),
        (homeApps, 0),
        (URL(fileURLWithPath: "/System/Applications", isDirectory: true), 1),
    ]
    for (root, priority) in roots where fm.fileExists(atPath: root.path) {
        scan(url: root, depth: 0, priority: priority, into: &found)
    }
    consider(
        url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        priority: 0,
        into: &found
    )
    return found.values.sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }.map { app in
        ["id": app.id, "name": app.name, "path": app.path]
    }
}

func scan(url: URL, depth: Int, priority: Int, into found: inout [String: ListedApp]) {
    guard depth <= 3 else { return }
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: []
    ) else { return }

    for item in items {
        let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isLink = values?.isSymbolicLink == true
        let isApp = item.pathExtension == "app"
        if isLink && !isApp { continue }
        if isApp {
            consider(url: item, priority: priority, into: &found)
            continue
        }
        if values?.isDirectory == true && depth < 3 {
            scan(url: item, depth: depth + 1, priority: priority, into: &found)
        }
    }
}

func consider(url: URL, priority: Int, into found: inout [String: ListedApp]) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
    guard let bundle = Bundle(url: url),
          let id = bundle.bundleIdentifier,
          !id.isEmpty else { return }
    let info = bundle.infoDictionary ?? [:]
    if (info["LSBackgroundOnly"] as? Bool) == true { return }
    if let kind = info["CFBundlePackageType"] as? String, kind != "APPL" && kind != "FNDR" { return }
    var label = fm.displayName(atPath: url.path)
    if label.hasSuffix(".app") {
        label = String(label.dropLast(4))
    }
    if label.isEmpty {
        label = url.deletingPathExtension().lastPathComponent
    }
    if let existing = found[id] {
        let better = priority < existing.priority
            || (priority == existing.priority && url.path.count < existing.path.count)
        if !better { return }
    }
    found[id] = ListedApp(id: id, name: label, path: url.path, priority: priority)
}

func exportIcon(src: String, dst: String) -> Bool {
    let icon = NSWorkspace.shared.icon(forFile: src)
    let pixels = 512
    let side = CGFloat(pixels)
    icon.size = NSSize(width: side, height: side)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return false }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try png.write(to: URL(fileURLWithPath: dst))
        return true
    } catch {
        fputs("\(error)\n", stderr)
        return false
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("uso: export-icon list|icon") }

switch args[1] {
case "list":
    do {
        let data = try JSONSerialization.data(withJSONObject: listApps())
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        fail("\(error)")
    }
case "icon":
    guard args.count >= 4 else { fail("uso: export-icon icon <app> <png>") }
    if !exportIcon(src: args[2], dst: args[3]) { exit(1) }
default:
    fail("comando desconhecido")
}

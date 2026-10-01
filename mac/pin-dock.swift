import Foundation

let appPath = CommandLine.arguments[1]
let appURL = URL(fileURLWithPath: appPath)
let bookmark = try appURL.bookmarkData(
    options: [.minimalBookmark],
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)

let export = FileManager.default.temporaryDirectory.appendingPathComponent("deck-dock.plist")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
task.arguments = ["export", "com.apple.dock", export.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    fputs("Não consegui ler a barra.\n", stderr)
    exit(1)
}

let data = try Data(contentsOf: export)
guard var root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
    fputs("Barra em formato inesperado.\n", stderr)
    exit(1)
}

var apps = root["persistent-apps"] as? [[String: Any]] ?? []
func sameApp(_ item: [String: Any]) -> Bool {
    guard let tile = item["tile-data"] as? [String: Any] else { return false }
    if (tile["file-label"] as? String) == "Deck" { return true }
    guard let book = tile["book"] as? Data else { return false }
    var stale = false
    guard let url = try? URL(
        resolvingBookmarkData: book,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
    ) else { return false }
    return url.path == appURL.path
}

let already = apps.contains(where: sameApp)

if !already {
    apps.append([
        "tile-data": [
            "book": bookmark,
            "file-label": "Deck",
            "file-type": 41,
        ],
        "tile-type": "file-tile",
    ])
    root["persistent-apps"] = apps
    let updated = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    try updated.write(to: export)
    let load = Process()
    load.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    load.arguments = ["import", "com.apple.dock", export.path]
    try load.run()
    load.waitUntilExit()
    guard load.terminationStatus == 0 else {
        fputs("Não consegui fixar na barra.\n", stderr)
        exit(1)
    }
    let restart = Process()
    restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    restart.arguments = ["Dock"]
    try restart.run()
    restart.waitUntilExit()
    print("fixado")
} else {
    print("ja-fixado")
}

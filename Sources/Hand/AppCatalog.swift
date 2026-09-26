import Foundation

struct InstalledApp: Hashable {
    let name: String
    let url: URL
}

/// Every .app in the usual install locations, one level of subfolders deep
/// (e.g. /Applications/Utilities, /Applications/Adobe Creative Cloud).
enum AppCatalog {
    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices/Finder.app/..",
            NSHomeDirectory() + "/Applications",
        ].map { URL(fileURLWithPath: $0).standardizedFileURL }

        var byName: [String: InstalledApp] = [:]
        func add(_ url: URL) {
            let name = url.deletingPathExtension().lastPathComponent
            if byName[name] == nil { byName[name] = InstalledApp(name: name, url: url) }
        }

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    if root.path == "/System/Library/CoreServices" && item.lastPathComponent != "Finder.app" { continue }
                    add(item)
                } else if root.path == "/Applications" || root.path == NSHomeDirectory() + "/Applications",
                          let nested = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    nested.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }
}

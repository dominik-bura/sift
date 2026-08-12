import AppKit

enum SiftAssets {
    static let menuBarIconName = NSImage.Name("SiftMenuBarIconTemplate")

    static let menuBarIcon: NSImage = {
        guard let url = Bundle.main.url(
            forResource: "SiftFunnel",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) else {
            assertionFailure("Sift menu-bar icon is missing from the application bundle")
            return NSImage(size: NSSize(width: 18, height: 18))
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.setName(menuBarIconName)
        return image
    }()

    static let applicationIcon: NSImage = {
        guard let url = Bundle.main.url(
            forResource: "SiftAppIcon-1024",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) else {
            assertionFailure("Sift application icon is missing from the application bundle")
            return NSApplication.shared.applicationIconImage
        }
        return image
    }()

    static func registerNamedImages() {
        _ = menuBarIcon
        _ = applicationIcon
    }
}

import Foundation

@objc(TGExtraEditHistoryAppearance)
final class EditHistoryAppearance: NSObject {
    @objc(buttonColorsFromNode:) static func buttonColors(from node: Any) -> [String: Any]? {
        var theme: Any = node
        for field in ["item", "presentationData", "theme"] {
            guard let next = HostValueReader.storedField(field, in: theme) else { return nil }
            theme = HostValueReader.unwrapOptional(next)
        }
        guard let wallpaper = HostValueReader.storedField("wallpaper", in: theme),
              let baseTheme = HostValueReader.storedField("theme", in: theme),
              let chat = HostValueReader.storedField("chat", in: baseTheme),
              let message = HostValueReader.storedField("message", in: chat) else { return nil }
        let wallpaperCase = Mirror(reflecting: HostValueReader.unwrapOptional(wallpaper)).children.first
        let plainWhite = wallpaperCase.map { $0.label == "color" && HostValueReader.rawNumber($0.value) == 0xffffff } ?? false
        let variant = plainWhite ? "withoutWallpaper" : "withWallpaper"
        var colors: [String: Any] = [:]
        for (key, field) in [("fill", "shareButtonFillColor"), ("foreground", "shareButtonForegroundColor"),
                             ("stroke", "shareButtonStrokeColor")] {
            guard let variable = HostValueReader.storedField(field, in: message),
                  let color = HostValueReader.storedField(variant, in: variable) else { continue }
            colors[key] = color
        }
        return colors.isEmpty ? nil : colors
    }
}

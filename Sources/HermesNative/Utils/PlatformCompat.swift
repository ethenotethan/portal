import SwiftUI

/// Cross-platform type aliases for macOS/iOS compatibility.
/// Use PlatformColor instead of NSColor/UIColor in SceneKit materials.
/// Use PlatformImage instead of NSImage/UIImage for image loading.
#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

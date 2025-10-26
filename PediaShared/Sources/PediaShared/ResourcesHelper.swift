//
//  ResourcesHelper.swift.swift
//  PediaShared
//
//  Created by yunastic on 10/25/25.
//

//
//  ResourcesHelper.swift
//  PediaShared
//

import Foundation

public enum BundleResources {
    /// The bundle that contains PediaShared resources.
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        // When built via Swift Package Manager without declared resources,
        // there is no synthesized `Bundle.module`. Use the main bundle.
        // If you later add resources to the package, you can restore `Bundle.module`.
        return Bundle.main
        #else
        // When built as an Xcode target (framework), use the bundle where this code lives.
        return Bundle(for: BundleToken.self)
        #endif
    }

    /// URL for a resource in the PediaShared bundle.
    public static func url(for name: String, ext: String) -> URL? {
        resourceBundle.url(forResource: name, withExtension: ext)
    }

    /// Convenience to load raw data.
    public static func data(for name: String, ext: String) -> Data? {
        guard let url = url(for: name, ext: ext) else { return nil }
        return try? Data(contentsOf: url)
    }
}

private final class BundleToken: NSObject {}

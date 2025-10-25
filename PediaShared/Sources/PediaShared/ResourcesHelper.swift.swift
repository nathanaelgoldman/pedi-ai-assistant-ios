//
//  ResourcesHelper.swift.swift
//  PediaShared
//
//  Created by yunastic on 10/25/25.
//

import Foundation

public enum BundleResources {
    public static func url(for name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext)
    }
}

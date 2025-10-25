//
//  Platform+Image.swift
//  PediaShared
//
//  Created by yunastic on 10/25/25.
//
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

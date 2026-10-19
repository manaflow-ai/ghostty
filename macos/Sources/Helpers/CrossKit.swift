// This file is a helper to bridge some types that are effectively identical
// between AppKit and UIKit.

#if canImport(AppKit)

import AppKit

typealias OSView = NSView
typealias OSColor = NSColor
typealias OSSize = NSSize
typealias OSPasteboard = NSPasteboard
typealias OSApplication = NSApplication

#elseif canImport(UIKit)

import UIKit

typealias OSView = UIView
typealias OSColor = UIColor
typealias OSSize = CGSize
typealias OSPasteboard = UIPasteboard
typealias OSApplication = UIApplication

#endif

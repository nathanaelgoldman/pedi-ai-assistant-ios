//
//  Theme.swift
//  PatientViewerApp
//
//  Created by Nathanael on 2/4/26.
//
import SwiftUI

enum AppTheme {
    // MARK: - Core palette (adaptive for Light/Dark)

    /// App background
    static var background: Color {
        Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                // Deeper blue-grey for dark mode
                return UIColor(red: 12.0/255.0, green: 22.0/255.0, blue: 38.0/255.0, alpha: 1.0)
            } else {
                // Your picked light background
                return UIColor(red: 173.0/255.0, green: 195.0/255.0, blue: 222.0/255.0, alpha: 1.0)
            }
        })
    }

    /// Cards / buttons background
    static var card: Color {
        Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                // Slightly lighter than background so cards pop
                return UIColor(red: 22.0/255.0, green: 36.0/255.0, blue: 58.0/255.0, alpha: 1.0)
            } else {
                // Your picked light card
                return UIColor(red: 242.0/255.0, green: 230.0/255.0, blue: 255.0/255.0, alpha: 1.0)
            }
        })
    }

    /// Subtle stroke for cards (dynamic system color)
    static var cardStroke: Color {
        Color(UIColor { traits in
            // Use a slightly stronger stroke in dark mode for definition
            if traits.userInterfaceStyle == .dark {
                return UIColor.separator.withAlphaComponent(0.45)
            } else {
                return UIColor.separator.withAlphaComponent(0.30)
            }
        })
    }
    
    /// Special-case card color for the patient header card (so it can be tuned independently).
    /// Default: same as `card`.
    static var patientHeaderCard: Color {
        Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                // tweak these 3 numbers for dark mode
                return UIColor(red: 22.0/255.0, green: 36.0/255.0, blue: 58.0/255.0, alpha: 1.0)
            } else {
                // tweak these 3 numbers for light mode
                return UIColor(red: 242.0/255.0, green: 255.0/255.0, blue: 245.0/255.0, alpha: 1.0)
            }
        })
    }

    // Optional helpers (nice for consistent styling)
    static let cornerRadius: CGFloat = 18
    static let smallCornerRadius: CGFloat = 14

    static var cardShadow: Color {
        Color(UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.black.withAlphaComponent(0.35)
            } else {
                return UIColor.black.withAlphaComponent(0.05)
            }
        })
    }
}

// MARK: - Reusable view modifiers

private struct AppBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AppTheme.background.ignoresSafeArea())
    }
}

private struct AppListBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background(AppTheme.background.ignoresSafeArea())
        } else {
            content
                .background(AppTheme.background)
        }
    }
}

private struct AppNavBarBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(AppTheme.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(scheme, for: .navigationBar)
        } else {
            content
        }
    }
}

extension View {
    /// Full-screen background matching the app theme.
    func appBackground() -> some View {
        self.modifier(AppBackgroundModifier())
    }

    /// Removes the default List scroll background tint and replaces it with the app theme background.
    func appListBackground() -> some View {
        self.modifier(AppListBackgroundModifier())
    }

    /// Forces the navigation bar background to match the app theme (iOS 16+).
    func appNavBarBackground() -> some View {
        self.modifier(AppNavBarBackgroundModifier())
    }
}

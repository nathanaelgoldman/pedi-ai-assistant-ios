//
//  Theme.swift
//  PatientViewerApp
//
//  Created by Nathanael on 2/4/26.
//
import SwiftUI

enum AppTheme {
    // MARK: - Core palette (your picked colors)
    static let background = Color(red: 198.0/255.0, green: 223.0/255.0, blue: 255.0/255.0) // app background
    static let card       = Color(red: 222.0/255.0, green: 227.0/255.0, blue: 243.0/255.0) // cards/buttons
    static let cardStroke = Color(.quaternaryLabel)

    // Optional helpers (nice for consistent styling)
    static let cornerRadius: CGFloat = 18
    static let smallCornerRadius: CGFloat = 14
    static let cardShadow = Color.black.opacity(0.05)
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
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(AppTheme.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
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

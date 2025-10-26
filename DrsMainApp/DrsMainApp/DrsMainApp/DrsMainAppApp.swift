//
//  DrsMainAppApp.swift
//  DrsMainApp
//
//  Created by yunastic on 10/25/25.
//

import SwiftUI

@main
struct DrsMainAppApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(appState)
        }
    }
}

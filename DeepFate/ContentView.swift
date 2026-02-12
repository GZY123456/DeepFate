import SwiftUI
import UIKit

struct ContentView: View {
    @State private var showSplash = true
    @State private var tabSelection: RootTab = .home
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var locationStore = LocationStore()
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var consultRouter = ConsultRouter()

    var body: some View {
        ZStack {
            if showSplash {
                SplashScreenView()
            } else {
                RootTabView(selection: $tabSelection, consultRouter: consultRouter)
                    .environmentObject(profileStore)
                    .environmentObject(locationStore)
                    .environmentObject(authViewModel)
                    .environmentObject(consultRouter)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeInOut) {
                    showSplash = false
                }
            }
        }
        .task {
            await locationStore.refresh()
        }
    }
}

private struct RootTabView: View {
    @Binding var selection: RootTab
    @ObservedObject var consultRouter: ConsultRouter
    @AppStorage("isLoggedIn") private var isLoggedIn = false
    private let coralAccent = Color(red: 1.0, green: 0.5412, blue: 0.3961) // #FF8A65

    init(selection: Binding<RootTab>, consultRouter: ConsultRouter) {
        _selection = selection
        _consultRouter = ObservedObject(wrappedValue: consultRouter)
        configureTabBarAppearance()
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("首页", systemImage: "house")
            }
            .tag(RootTab.home)

            NavigationStack {
                MainView()
            }
            .tabItem {
                Label("咨询", systemImage: "message")
            }
            .tag(RootTab.explore)

            NavigationStack {
                XiuXinView()
            }
            .tabItem {
                Label("修心", systemImage: "leaf")
            }
            .tag(RootTab.xiuxin)

            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("我的", systemImage: "person")
            }
            .tag(RootTab.profile)
        }
        .background(
            Color(red: 0.95, green: 0.92, blue: 0.86)
                .ignoresSafeArea()
        )
        .tint(coralAccent)
        .onChange(of: consultRouter.switchToConsultTab) { _, shouldSwitch in
            if shouldSwitch {
                selection = .explore
                consultRouter.switchToConsultTab = false
            }
        }
    }

    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 0.96)
        appearance.shadowColor = UIColor(red: 0.72, green: 0.64, blue: 0.53, alpha: 0.35)

        let normalColor = UIColor(red: 0.3647, green: 0.2510, blue: 0.2157, alpha: 0.68)
        let selectedColor = UIColor(red: 1.0, green: 0.5412, blue: 0.3961, alpha: 1.0)

        appearance.stackedLayoutAppearance.normal.iconColor = normalColor
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
        appearance.stackedLayoutAppearance.selected.iconColor = selectedColor
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = normalColor
    }
}

enum RootTab: Hashable {
    case home
    case explore
    case xiuxin
    case profile
}

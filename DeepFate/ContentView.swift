import SwiftUI

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
        .tint(.purple)
        .onChange(of: consultRouter.switchToConsultTab) { shouldSwitch in
            if shouldSwitch {
                selection = .explore
                consultRouter.switchToConsultTab = false
            }
        }
    }
}

enum RootTab: Hashable {
    case home
    case explore
    case xiuxin
    case profile
}

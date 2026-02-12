import SwiftUI
import UIKit

@main
struct DeepFateApp: App {
    init() {
        let textField = UITextField.appearance()
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []

        // 将窗口底色从默认白色改为应用主题色，避免任何布局间隙显示为白色
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows {
                    window.backgroundColor = UIColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 1.0)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
                .onAppear {
                    // init 时窗口可能还未就绪，在 onAppear 时再设置一次
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first {
                        window.backgroundColor = UIColor(red: 0.95, green: 0.92, blue: 0.86, alpha: 1.0)
                    }
                }
        }
    }
}

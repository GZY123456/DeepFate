import SwiftUI
import UIKit

@main
struct DeepFateApp: App {
    init() {
        let textField = UITextField.appearance()
        textField.inputAssistantItem.leadingBarButtonGroups = []
        textField.inputAssistantItem.trailingBarButtonGroups = []
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

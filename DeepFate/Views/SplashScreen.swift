import SwiftUI

struct SplashScreenView: View {
    @State private var showSlogan = false

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                Image("LaunchImageV2")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .ignoresSafeArea()

            VStack {
                Spacer()
                Spacer()

                Text("DeepFate\n抽卡拯救世界")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .foregroundStyle(Color(red: 0.9, green: 0.85, blue: 0.7))
                    .opacity(showSlogan ? 1 : 0)

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1).delay(0.5)) {
                showSlogan = true
            }
        }
    }
}

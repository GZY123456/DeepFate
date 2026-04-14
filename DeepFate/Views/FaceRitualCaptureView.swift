import SwiftUI
import AVFoundation
import ARKit
import SceneKit
import simd

private enum FaceRitualPhase {
    case ready
    case loading
    case recognizing
    case activated
    case opening
    case generating  // 抽取结果生成中（等服务端返回后再 dismiss）
}

private enum FaceRitualStep: Int, CaseIterable {
    case turnLeft   // 0 → 第一步
    case turnRight  // 1 → 第二步
    case openMouth  // 2 → 第三步

    var title: String {
        switch self {
        case .turnLeft:  return "左转头"
        case .turnRight: return "右转头"
        case .openMouth: return "张嘴"
        }
    }

    var icon: String {
        switch self {
        case .turnLeft:  return "arrow.left"
        case .turnRight: return "arrow.right"
        case .openMouth: return "arrow.up.and.down"
        }
    }
}

struct FaceRitualCaptureView: View {
    let onSuccess: () async -> Void
    let onUseRandomFallback: () async -> Void
    var onSwitchUser: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var profileStore: ProfileStore
    @StateObject private var detector = FaceRitualDetector()

    @State private var phase: FaceRitualPhase = .ready
    @State private var remainingSeconds = 60
    @State private var timerTask: Task<Void, Never>?
    @State private var showPermissionAlert = false
    @State private var showUnsupportedAlert = false
    @State private var showTimeoutAlert = false
    @State private var showGeneralErrorAlert = false
    @State private var activationPulse = false
    @State private var cloudBreath = false
    @State private var crackProgress: CGFloat = 0
    @State private var hintPulse = false

    private let deepAmber = Color(red: 0.40, green: 0.23, blue: 0.10)
    private let warmCard = Color(red: 1.0, green: 0.98, blue: 0.94).opacity(0.86)
    private let gold = Color(red: 0.93, green: 0.79, blue: 0.44)
    private let coral = Color(red: 0.98, green: 0.50, blue: 0.40)

    private let sideSticks = [
        "上上签·万事胜意",
        "大吉签·财源广进",
        "平安签·诸事顺遂",
        "小吉签·遇难呈祥"
    ]

    var body: some View {
        Group {
            if phase == .ready {
                readyOnlyView
            } else {
                recognitionView
            }
        }
        .onAppear {
            if phase != .ready {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    cloudBreath = true
                }
            }
        }
        .onDisappear {
            timerTask?.cancel()
            detector.stop()
        }
        .onChange(of: detector.completedStepCount) { _, newValue in
            if newValue >= FaceRitualStep.allCases.count {
                recognitionFinished()
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .recognizing {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    hintPulse = true
                }
            } else {
                hintPulse = false
            }
        }
        .alert("需要相机权限", isPresented: $showPermissionAlert) {
            Button("改为随机抽卡") {
                Task {
                    await onUseRandomFallback()
                    await MainActor.run { dismiss() }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("你拒绝了相机权限，本次抽卡可改为随机抽卡。")
        }
        .alert("设备不支持相面识别", isPresented: $showUnsupportedAlert) {
            Button("改为随机抽卡") {
                Task {
                    await onUseRandomFallback()
                    await MainActor.run { dismiss() }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("当前设备不支持面容追踪，将为你切换到随机抽卡。")
        }
        .alert("识别超时", isPresented: $showTimeoutAlert) {
            Button("重新识别") {
                resetToReady()
            }
            Button("取消", role: .cancel) {
                resetToReady()
            }
        } message: {
            Text("超过 60 秒仍未完成动作，请重新开始。")
        }
        .alert("识别异常", isPresented: $showGeneralErrorAlert) {
            Button("重新识别") {
                resetToReady()
            }
            Button("取消", role: .cancel) {
                resetToReady()
            }
        } message: {
            Text("相机会话启动失败，请重试。")
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var readyProfileName: String {
        guard let id = profileStore.activeProfileID,
              let profile = profileStore.profiles.first(where: { $0.id == id }) else {
            return "档案"
        }
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "档案" : String(trimmed.prefix(4))
    }

    private var readyOnlyView: some View {
        let pinkFade = Color(red: 1.0, green: 0.82, blue: 0.88)

        return ZStack {
            Image("FaceRitualBackground")
                .resizable()
                .scaledToFill()
                .blur(radius: 4)
                .overlay(pinkFade.opacity(0.48))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部导航栏
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .medium))
                            Text("返回首页")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    Button {
                        dismiss()
                        onSwitchUser?()
                    } label: {
                        HStack(spacing: 6) {
                            ProfileAvatarView(name: readyProfileName, size: 22)
                            Text(readyProfileName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // 八卦镜（最上层）
                Image("BaguaMirror")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, -4)
                    .padding(.top, 14)
                    .zIndex(2)

                // 云纹（中间层，往上移与镜底重叠更多）
                Image("CloudDivider")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(.top, -36)
                    .zIndex(1)

                // 签子区（最底层），整体上移，签子放大
                let vOffsets: [CGFloat] = [-36, -18, 0, -18, -36]
                let tagImages = ["FortuneTag", "FortuneTagMarryLuck", "FortuneTagMidLuck", "FortuneTagTransLuck", "FortuneTagLargeLuck"]
                GeometryReader { geo in
                    let tagWidth = (geo.size.width - 16) / 5
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<5, id: \.self) { i in
                            Image(tagImages[i])
                                .resizable()
                                .scaledToFit()
                                .frame(width: tagWidth)
                                .offset(y: vOffsets[i])
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(width: geo.size.width)
                }
                .frame(height: 240)
                .padding(.top, -28)
                .zIndex(0)

                Spacer(minLength: 8)

                // 开始按钮
                Button {
                    beginFlow()
                } label: {
                    Text("刷脸解锁今日运势")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .frame(width: 200)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(coral)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                )
                                .shadow(color: coral.opacity(0.4), radius: 8, x: 0, y: 4)
                        )
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Recognition View (识别进行中)

    private var recognitionView: some View {
        let pinkFade = Color(red: 1.0, green: 0.82, blue: 0.88)
        return ZStack {
            Image("FaceRitualBackground")
                .resizable()
                .scaledToFill()
                .blur(radius: 4)
                .overlay(pinkFade.opacity(0.48))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                recognitionNavBar

                recognitionMirrorSection
                    .zIndex(2)

                Image("CloudDivider")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(.top, -14)   // 减少重叠，加大间距
                    .zIndex(1)

                actionHintsColumn
                    .padding(.top, 4)
                    .zIndex(0)

                Spacer(minLength: 0)

                drawFortuneButton
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Text("限时 \(remainingSeconds <= 0 ? 60 : remainingSeconds) 秒，超时可重新识别")
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(phase == .recognizing ? 1 : 0)
                    .padding(.bottom, 16)
            }
        }
    }

    private var recognitionNavBar: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                    Text("返回首页")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            Button { dismiss(); onSwitchUser?() } label: {
                HStack(spacing: 6) {
                    ProfileAvatarView(name: readyProfileName, size: 22)
                    Text(readyProfileName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var recognitionMirrorSection: some View {
        GeometryReader { proxy in
            let mirrorSize = min(proxy.size.width * 0.86, 330)
            let cameraSize = mirrorSize * 0.54   // 稍小一点，确保在透明圆孔范围内
            ZStack {
                // 1. 最底层：八卦镜图片
                Image("BaguaMirror")
                    .resizable()
                    .scaledToFit()
                    .frame(width: mirrorSize, height: mirrorSize)
                    .shadow(
                        color: gold.opacity(phase == .activated ? 0.7 : 0.35),
                        radius: phase == .activated ? 20 : 10,
                        x: 0, y: 4
                    )

                // 2. 最上层：摄像头画面覆盖镜子中心（BaguaMirror 中心是不透明的，需要直接覆盖）
                FaceCameraPreviewView(detector: detector)
                    .frame(width: cameraSize, height: cameraSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.5), Color.white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 300)
        .padding(.top, 8)
    }

    private var actionHintsColumn: some View {
        VStack(spacing: 10) {
            ForEach(FaceRitualStep.allCases, id: \.rawValue) { step in
                let done = detector.stepDone(step)
                let isCurrent = step.rawValue == detector.completedStepCount && phase == .recognizing

                HStack(spacing: 14) {
                    // 左侧状态圆形徽章
                    ZStack {
                        Circle()
                            .fill(
                                done    ? gold.opacity(0.22) :
                                isCurrent ? coral.opacity(0.22) :
                                Color.white.opacity(0.10)
                            )
                            .frame(width: 46, height: 46)
                        Circle()
                            .stroke(
                                done    ? gold.opacity(0.55) :
                                isCurrent ? coral.opacity(0.60) :
                                Color.white.opacity(0.18),
                                lineWidth: 1.2
                            )
                            .frame(width: 46, height: 46)

                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(gold)
                        } else if isCurrent {
                            Image(systemName: step.icon)   // 左转头→arrow.left，右转头→arrow.right，张嘴→上下箭头
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(coral)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                                .foregroundStyle(Color.white.opacity(0.40))
                        }
                    }

                    // 中间文字
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.system(size: 22, weight: .semibold, design: .serif))
                            .foregroundStyle(
                                done    ? gold :
                                isCurrent ? Color.white :
                                Color.white.opacity(0.45)
                            )
                        Text(
                            done      ? "已完成" :
                            isCurrent ? "请完成此动作" :
                            "等待中"
                        )
                        .font(.system(size: 13, weight: .regular, design: .serif))
                        .foregroundStyle(
                            done      ? gold.opacity(0.75) :
                            isCurrent ? Color.white.opacity(0.80) :
                            Color.white.opacity(0.30)
                        )
                    }

                    Spacer()

                    // 右侧当前动作箭头
                    if isCurrent {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(coral.opacity(0.80))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            done    ? gold.opacity(0.10) :
                            isCurrent ? coral.opacity(0.13) :
                            Color.white.opacity(0.07)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(
                                    done    ? gold.opacity(0.40) :
                                    isCurrent ? coral.opacity(0.50) :
                                    Color.white.opacity(0.13),
                                    lineWidth: 1
                                )
                        )
                )
                .scaleEffect(isCurrent ? (hintPulse ? 1.02 : 1.0) : 1.0)
                .animation(
                    isCurrent ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                    value: hintPulse
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private var drawFortuneButton: some View {
        let canDraw = phase == .activated
        let isGenerating = phase == .generating
        return Button {
            openSealedStick()
        } label: {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text(isGenerating ? "正在推算命盘..." : "抽取今日运势")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
            }
            .foregroundStyle(.white)
            .frame(width: 220)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isGenerating ? coral.opacity(0.60) :
                        canDraw      ? coral :
                        Color.white.opacity(0.22)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity((canDraw || isGenerating) ? 0.35 : 0.15), lineWidth: 1)
                    )
                    .shadow(
                        color: (canDraw || isGenerating) ? coral.opacity(0.5) : .clear,
                        radius: 10, x: 0, y: 5
                    )
            )
        }
        .disabled(!canDraw)
        .scaleEffect(canDraw && hintPulse ? 1.02 : 1.0)
        .animation(
            canDraw ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
            value: hintPulse
        )
    }

    // MARK: - Legacy views (used only in readyOnlyView context)

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.86, blue: 0.84),
                    Color(red: 0.97, green: 0.82, blue: 0.86),
                    Color(red: 0.93, green: 0.79, blue: 0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.34),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 8,
                endRadius: 340
            )

            RoundedRectangle(cornerRadius: 0)
                .fill(Color.white.opacity(0.08))
                .background(.ultraThinMaterial)
        }
        .blur(radius: 40)
        .overlay(
            Color(red: 0.98, green: 0.90, blue: 0.90).opacity(0.30)
        )
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(deepAmber)
                        .frame(width: 34, height: 34)
                }

                Spacer()

                Button {
                    dismiss()
                    onSwitchUser?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2")
                            .font(.system(size: 18, weight: .medium))
                        Text("切换用户")
                            .font(.system(size: 16, weight: .medium, design: .serif))
                    }
                    .foregroundStyle(deepAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }

            Text("今日运势 · 相面抽卡")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(deepAmber)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(height: 48)
        .padding(.top, 8)
    }

    private var mirrorSection: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width * 0.82, 320)
            let cameraSize = size * 0.56

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: cameraSize, height: cameraSize)
                    .overlay(
                        FaceCameraPreviewView(detector: detector)
                            .clipShape(Circle())
                    )
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.clear, Color.pink.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        Circle().stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )

                Image("BaguaMirror")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .shadow(color: gold.opacity(phase == .recognizing || phase == .activated ? 0.5 : 0.2),
                            radius: phase == .recognizing || phase == .activated ? 16 : 6,
                            x: 0, y: 4)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 340)
    }

    private var cloudBridge: some View {
        HStack(spacing: -16) {
            ForEach(0..<6, id: \.self) { idx in
                Ellipse()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: idx.isMultiple(of: 2) ? 90 : 76, height: idx.isMultiple(of: 2) ? 42 : 34)
                    .blur(radius: 1.6)
            }
        }
        .scaleEffect(cloudBreath ? 1.03 : 0.97)
        .opacity(cloudBreath ? 0.92 : 0.72)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: cloudBreath)
        .padding(.top, -28)
    }

    private var fortunePanel: some View {
        VStack(spacing: 14) {
            stepStatusRow

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(warmCard)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)

                HStack(alignment: .top, spacing: 14) {
                    FortuneStickView(text: sideSticks[0], deepAmber: deepAmber)
                    FortuneStickView(text: sideSticks[1], deepAmber: deepAmber)
                    centerFortuneStick
                    FortuneStickView(text: sideSticks[2], deepAmber: deepAmber)
                    FortuneStickView(text: sideSticks[3], deepAmber: deepAmber)
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .frame(height: 278)

            Button {
                beginFlow()
            } label: {
                HStack(spacing: 8) {
                    if phase == .loading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                    Text(actionButtonTitle)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(coral)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        )
                        .shadow(color: coral.opacity(0.45), radius: 12, x: 0, y: 7)
                )
            }
            .disabled(actionDisabled)
            .opacity(actionDisabled ? 0.75 : 1)

            Text("限时 \(remainingSeconds <= 0 ? 60 : remainingSeconds) 秒，超时可重新识别")
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundStyle(Color.gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

            Text("DeepFate全力保护用户隐私，本次人脸识别不会上传。")
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundStyle(Color(red: 0.42, green: 0.31, blue: 0.24))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var stepStatusRow: some View {
        HStack(spacing: 8) {
            ForEach(FaceRitualStep.allCases, id: \.rawValue) { step in
                let done = detector.stepDone(step)
                Text(step.title)
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(done ? deepAmber : deepAmber.opacity(0.62))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(done ? gold.opacity(0.34) : Color.white.opacity(0.45))
                    )
                    .overlay(
                        Capsule().stroke(done ? gold.opacity(0.7) : Color.white.opacity(0.40), lineWidth: 1)
                    )
            }
        }
    }

    private var centerFortuneStick: some View {
        VStack(spacing: 6) {
            if phase == .activated {
                Text("点击开启今日天机")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .foregroundStyle(Color(red: 0.43, green: 0.24, blue: 0.17))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Color.clear.frame(height: 28)
            }

            Button {
                openSealedStick()
            } label: {
                SealedFortuneStickView(
                    isActivated: phase == .activated,
                    crackProgress: crackProgress,
                    deepAmber: deepAmber,
                    gold: gold
                )
                .scaleEffect(phase == .activated ? (activationPulse ? 1.04 : 0.98) : 1.0)
                .shadow(color: (phase == .activated ? gold : Color.clear).opacity(0.75), radius: phase == .activated ? 18 : 0, x: 0, y: 8)
                .animation(
                    phase == .activated
                    ? .easeInOut(duration: 0.32).repeatForever(autoreverses: true)
                    : .default,
                    value: activationPulse
                )
            }
            .buttonStyle(.plain)
            .disabled(phase != .activated)
        }
        .frame(width: 66)
        .onChange(of: phase) { _, newValue in
            if newValue == .activated {
                activationPulse = true
            } else {
                activationPulse = false
            }
        }
    }

    private var actionButtonTitle: String {
        switch phase {
        case .ready:
            return "开始相面识别"
        case .loading:
            return "连接乾坤镜..."
        case .recognizing:
            return "识别中 \(detector.completedStepCount)/3"
        case .activated:
            return "识别完成，请点中间灵签"
        case .opening:
            return "开启天机中..."
        case .generating:
            return "正在推算命盘..."
        }
    }

    private var actionDisabled: Bool {
        switch phase {
        case .ready:
            return false
        case .loading, .recognizing, .activated, .opening, .generating:
            return true
        }
    }

    private func beginFlow() {
        guard phase == .ready else { return }
        guard FaceRitualDetector.isSupported else {
            showUnsupportedAlert = true
            return
        }
        phase = .loading
        Task {
            let granted = await detector.requestCameraAccess()
            await MainActor.run {
                if !granted {
                    phase = .ready
                    showPermissionAlert = true
                    return
                }
                do {
                    try detector.start()
                    phase = .recognizing
                    startTimer()
                } catch {
                    phase = .ready
                    showGeneralErrorAlert = true
                }
            }
        }
    }

    @MainActor
    private func recognitionFinished() {
        guard phase == .recognizing else { return }
        phase = .activated
        timerTask?.cancel()
    }

    private func openSealedStick() {
        guard phase == .activated else { return }
        phase = .generating
        detector.stop()
        timerTask?.cancel()
        Task {
            // 先在后台生成结果，完成后再 dismiss——用户不会看到符咒界面的闪烁
            await onSuccess()
            await MainActor.run { dismiss() }
        }
    }

    @MainActor
    private func resetToReady() {
        timerTask?.cancel()
        detector.stop()
        detector.resetSteps()
        phase = .ready
        crackProgress = 0
        remainingSeconds = 60
    }

    private func startTimer() {
        timerTask?.cancel()
        remainingSeconds = 60
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    guard phase == .recognizing else { return }
                    remainingSeconds -= 1
                    if remainingSeconds <= 0 {
                        timerTask?.cancel()
                        detector.stop()
                        showTimeoutAlert = true
                    }
                }
            }
        }
    }
}

private struct BaguaMirrorView: View {
    let litCount: Int
    let glow: Bool
    let gold: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.58, green: 0.35, blue: 0.18),
                            Color(red: 0.42, green: 0.26, blue: 0.14)
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 260
                    )
                )
                .overlay(
                    Circle()
                        .stroke(gold.opacity(0.92), lineWidth: 8)
                )
                .shadow(color: gold.opacity(glow ? 0.48 : 0.2), radius: glow ? 20 : 8, x: 0, y: 4)

            Circle()
                .stroke(gold.opacity(0.85), lineWidth: 3)
                .padding(12)

            ForEach(0..<8, id: \.self) { index in
                let isLit = index < min(max(litCount, 0), 3)
                Capsule()
                    .fill(isLit ? gold : Color(red: 0.78, green: 0.64, blue: 0.42).opacity(0.60))
                    .frame(width: 8, height: 30)
                    .shadow(color: isLit ? gold.opacity(0.75) : .clear, radius: 6, x: 0, y: 0)
                    .offset(y: -153)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
        }
    }
}

private struct FortuneStickView: View {
    let text: String
    let deepAmber: Color

    var body: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(Color(red: 0.78, green: 0.15, blue: 0.18))
                .frame(width: 2, height: 24)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.93, green: 0.78, blue: 0.53),
                            Color(red: 0.78, green: 0.60, blue: 0.35)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(red: 0.67, green: 0.48, blue: 0.25), lineWidth: 1)
                )
                .overlay(
                    Text(vertical(text))
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundStyle(deepAmber)
                        .lineSpacing(1)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 12)
                )
                .frame(width: 58, height: 176)
        }
    }

    private func vertical(_ source: String) -> String {
        source.map { String($0) }.joined(separator: "\n")
    }
}

private struct SealedFortuneStickView: View {
    let isActivated: Bool
    let crackProgress: CGFloat
    let deepAmber: Color
    let gold: Color

    var body: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(Color(red: 0.78, green: 0.15, blue: 0.18))
                .frame(width: 2, height: 24)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.93, green: 0.78, blue: 0.53),
                                Color(red: 0.78, green: 0.60, blue: 0.35)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(red: 0.67, green: 0.48, blue: 0.25), lineWidth: 1)
                    )

                if crackProgress < 1 {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.73, green: 0.33, blue: 0.24).opacity(0.82))
                        .frame(width: 34, height: 126)
                        .overlay(
                            SealPattern()
                                .stroke(Color(red: 0.46, green: 0.17, blue: 0.14).opacity(0.65), lineWidth: 1)
                                .padding(8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 0.45, green: 0.16, blue: 0.12).opacity(0.45), lineWidth: 1)
                        )
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.73, green: 0.33, blue: 0.24).opacity(0.80))
                            .frame(width: 16, height: 122)
                            .offset(x: -11, y: -2)
                            .rotationEffect(.degrees(-16))
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.73, green: 0.33, blue: 0.24).opacity(0.80))
                            .frame(width: 16, height: 122)
                            .offset(x: 11, y: 2)
                            .rotationEffect(.degrees(15))
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: 58, height: 176)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isActivated ? gold.opacity(0.95) : .clear, lineWidth: 1.6)
            )
        }
    }
}

private struct SealPattern: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        path.move(to: CGPoint(x: width * 0.20, y: height * 0.10))
        path.addLine(to: CGPoint(x: width * 0.80, y: height * 0.15))
        path.addLine(to: CGPoint(x: width * 0.50, y: height * 0.34))
        path.addLine(to: CGPoint(x: width * 0.72, y: height * 0.54))
        path.addLine(to: CGPoint(x: width * 0.34, y: height * 0.76))
        path.addLine(to: CGPoint(x: width * 0.62, y: height * 0.88))
        path.move(to: CGPoint(x: width * 0.16, y: height * 0.50))
        path.addLine(to: CGPoint(x: width * 0.84, y: height * 0.50))
        return path
    }
}

private struct FaceCameraPreviewView: UIViewRepresentable {
    @ObservedObject var detector: FaceRitualDetector

    func makeUIView(context: Context) -> ARSCNView {
        detector.sceneView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        uiView.backgroundColor = .clear
    }
}

private final class FaceRitualDetector: NSObject, ObservableObject, ARSessionDelegate {
    enum DetectorError: Error {
        case unsupported
    }

    @Published private(set) var completedStepCount = 0
    @Published private(set) var doneSteps: [Bool] = Array(repeating: false, count: FaceRitualStep.allCases.count)

    static var isSupported: Bool {
        ARFaceTrackingConfiguration.isSupported
    }

    let sceneView = ARSCNView(frame: .zero)

    private var isRunning = false
    private var currentStep = 0

    override init() {
        super.init()
        sceneView.backgroundColor = .clear
        sceneView.scene = SCNScene()
        sceneView.automaticallyUpdatesLighting = true
        sceneView.delegate = self
        sceneView.session.delegate = self
    }

    deinit {
        sceneView.session.pause()
    }

    func requestCameraAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    func start() throws {
        guard Self.isSupported else {
            throw DetectorError.unsupported
        }
        resetSteps()
        isRunning = true
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        isRunning = false
        sceneView.session.pause()
    }

    @MainActor
    func resetSteps() {
        currentStep = 0
        completedStepCount = 0
        doneSteps = Array(repeating: false, count: FaceRitualStep.allCases.count)
    }

    func stepDone(_ step: FaceRitualStep) -> Bool {
        doneSteps.indices.contains(step.rawValue) ? doneSteps[step.rawValue] : false
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isRunning else { return }
        guard let anchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        let jawOpen = anchor.blendShapes[.jawOpen]?.floatValue ?? 0
        let yaw = yawFromTransform(anchor.transform)

        DispatchQueue.main.async { [weak self] in
            self?.consume(jawOpen: jawOpen, yaw: yaw)
        }
    }

    private func consume(jawOpen: Float, yaw: Float) {
        guard isRunning else { return }
        guard currentStep < FaceRitualStep.allCases.count else { return }

        switch currentStep {
        case FaceRitualStep.openMouth.rawValue:
            if jawOpen > 0.33 {
                mark(step: .openMouth)
            }
        case FaceRitualStep.turnLeft.rawValue:
            if yaw < -0.24 {   // 用户物理左转 → yaw 为负
                mark(step: .turnLeft)
            }
        case FaceRitualStep.turnRight.rawValue:
            if yaw > 0.24 {    // 用户物理右转 → yaw 为正
                mark(step: .turnRight)
            }
        default:
            break
        }
    }

    private func mark(step: FaceRitualStep) {
        guard doneSteps.indices.contains(step.rawValue) else { return }
        guard !doneSteps[step.rawValue] else { return }
        doneSteps[step.rawValue] = true
        currentStep += 1
        completedStepCount = doneSteps.filter { $0 }.count
    }

    private func yawFromTransform(_ transform: simd_float4x4) -> Float {
        let q = simd_quatf(transform)
        let siny = 2 * (q.real * q.imag.y + q.imag.x * q.imag.z)
        let cosy = 1 - 2 * (q.imag.y * q.imag.y + q.imag.z * q.imag.z)
        return atan2(siny, cosy)
    }
}

extension FaceRitualDetector: ARSCNViewDelegate {}

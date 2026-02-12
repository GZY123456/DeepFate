import SwiftUI

struct CreateProfileSheet: View {
    let provinces: [ProvinceOption]
    let existingProfile: UserProfile?
    let onCreate: (UserProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    private let locationSearchClient = LocationSearchClient()
    @State private var step: Int = 0
    @State private var name: String
    @State private var gender: Gender
    @State private var birthInput: BirthInput
    @State private var birthInfo: BirthInfo?
    @State private var errorMessage: String?
    @State private var showLocationHelp = false
    @State private var locationQuery: String
    @State private var locationSuggestions: [GeoLocationSuggestion]
    @State private var selectedLocation: GeoLocationSuggestion?
    @State private var isSearchingLocation: Bool

    init(
        provinces: [ProvinceOption],
        existingProfile: UserProfile? = nil,
        onCreate: @escaping (UserProfile) -> Void
    ) {
        self.provinces = provinces
        self.existingProfile = existingProfile
        self.onCreate = onCreate

        if let profile = existingProfile {
            let solar = profile.birthInfo.solarComponents
            let prefill = BirthInput(
                calendarType: .solar,
                year: solar.year ?? 2000,
                month: solar.month ?? 1,
                day: solar.day ?? 1,
                hour: solar.hour ?? 0,
                isLeapMonth: false
            )
            _name = State(initialValue: profile.name)
            _gender = State(initialValue: profile.gender)
            _birthInput = State(initialValue: prefill)
            _birthInfo = State(initialValue: profile.birthInfo)
            let existingLocation = GeoLocationSuggestion(
                id: profile.id.uuidString,
                name: profile.location.district.isEmpty ? profile.location.city : profile.location.district,
                province: profile.location.province,
                city: profile.location.city,
                district: profile.location.district,
                detailAddress: profile.location.detailAddress,
                fullAddress: profile.location.fullDisplayText,
                longitude: profile.location.longitude,
                latitude: profile.location.latitude,
                timezoneID: profile.location.timezoneID,
                utcOffsetMinutes: profile.location.utcOffsetMinutesAtBirth,
                source: profile.location.placeSource,
                adcode: profile.location.locationAdcode
            )
            _locationQuery = State(initialValue: profile.location.fullDisplayText)
            _locationSuggestions = State(initialValue: [])
            _selectedLocation = State(initialValue: existingLocation)
            _isSearchingLocation = State(initialValue: false)
        } else {
            _name = State(initialValue: "")
            _gender = State(initialValue: .female)
            _birthInput = State(initialValue: BirthInput.defaultValue)
            _birthInfo = State(initialValue: nil)
            _locationQuery = State(initialValue: "")
            _locationSuggestions = State(initialValue: [])
            _selectedLocation = State(initialValue: nil)
            _isSearchingLocation = State(initialValue: false)
        }
    }

    private var longitudeOffsetMinutes: Int {
        let offset = ((selectedLocation?.longitude ?? 120.0) - 120.0) * 4.0
        return Int(offset.rounded())
    }

    private var trueSolarComponents: DateComponents? {
        guard let birthInfo else { return nil }
        return computeTrueSolarComponents(from: birthInfo.solarComponents, longitude: selectedLocation?.longitude ?? 120.0)
    }

    private var isEditing: Bool {
        existingProfile != nil
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? "编辑档案" : "创建档案")
                .font(.headline)
                .padding(.top, 8)

            StepIndicator(currentStep: step)

            Group {
                switch step {
                case 0:
                    ProfileBasicStep(name: $name, gender: $gender)
                case 1:
                    BirthTimeStep(input: $birthInput, errorMessage: $errorMessage)
                default:
                    BirthLocationStep(
                        query: $locationQuery,
                        suggestions: locationSuggestions,
                        selectedLocation: $selectedLocation,
                        isSearching: isSearchingLocation,
                        showHelp: $showLocationHelp,
                        longitudeOffsetMinutes: longitudeOffsetMinutes,
                        trueSolarComponents: trueSolarComponents
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                if step > 0 {
                    Button("上一步") {
                        step -= 1
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                let actionTitle = step == 2 ? (isEditing ? "保存修改" : "创建档案") : "下一步"
                Button(actionTitle) {
                    handlePrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal)
        .onChange(of: locationQuery) { _, newValue in
            scheduleLocationSearch(for: newValue)
            if selectedLocation?.displayAddress != newValue {
                selectedLocation = nil
            }
        }
        .alert("说明", isPresented: $showLocationHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("由于太阳升起的时间因地而异，我们需要精确的地点来计算您出生时的真太阳时，以确保命盘解析的准确性。")
        }
    }

    private var canProceed: Bool {
        switch step {
        case 0:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1:
            return true
        default:
            return selectedLocation != nil
        }
    }

    private func handlePrimaryAction() {
        switch step {
        case 0:
            errorMessage = nil
            step = 1
        case 1:
            if let validationError = validate(birthInput) {
                errorMessage = validationError
                return
            }
            guard let info = makeBirthInfo(from: birthInput) else {
                errorMessage = "日期无效，请检查年月日是否正确。"
                return
            }
            birthInfo = info
            errorMessage = nil
            step = 2
        default:
            guard let birthInfo,
                  let selectedLocation,
                  let trueSolarComponents else {
                errorMessage = "无法计算真太阳时，请确认出生时间与地点。"
                return
            }
            let location = BirthLocation(
                province: selectedLocation.province,
                city: selectedLocation.city,
                district: selectedLocation.district,
                detailAddress: selectedLocation.detailAddress,
                latitude: selectedLocation.latitude,
                longitude: selectedLocation.longitude,
                timezoneID: selectedLocation.timezoneID,
                utcOffsetMinutesAtBirth: selectedLocation.utcOffsetMinutes,
                placeSource: selectedLocation.source,
                locationAdcode: selectedLocation.adcode
            )
            let profile = UserProfile(
                id: existingProfile?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                gender: gender,
                birthInfo: birthInfo,
                location: location,
                trueSolarComponents: trueSolarComponents,
                createdAt: existingProfile?.createdAt ?? Date()
            )
            onCreate(profile)
            dismiss()
        }
    }

    private func scheduleLocationSearch(for keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            locationSuggestions = []
            isSearchingLocation = false
            return
        }
        isSearchingLocation = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let items = try await locationSearchClient.search(keyword: trimmed, limit: 12)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard locationQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                    locationSuggestions = items
                    isSearchingLocation = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard locationQuery.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                    locationSuggestions = []
                    isSearchingLocation = false
                }
            }
        }
    }
}

private struct StepIndicator: View {
    let currentStep: Int

    var body: some View {
        HStack(spacing: 8) {
            StepDot(title: "基本信息", isActive: currentStep == 0)
            StepDot(title: "出生时间", isActive: currentStep == 1)
            StepDot(title: "出生地", isActive: currentStep == 2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct StepDot: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.purple : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }
}

private struct ProfileBasicStep: View {
    @Binding var name: String
    @Binding var gender: Gender

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("姓名")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("请输入姓名", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("性别")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("性别", selection: $gender) {
                ForEach(Gender.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 140)
        }
    }
}

private struct BirthTimeStep: View {
    @Binding var input: BirthInput
    @Binding var errorMessage: String?

    private var monthOptions: [(value: Int, label: String)] {
        (1...12).map { month in
            let label: String
            if input.calendarType == .lunar {
                label = lunarMonthNames[month - 1]
            } else {
                label = solarMonthNames[month - 1]
            }
            return (month, label)
        }
    }

    private var dayRange: [Int] {
        let maxDay = daysInMonth(for: input)
        return Array(1...maxDay)
    }

    private var showLeapMonthToggle: Bool {
        if #available(iOS 17.0, *) {
            return input.calendarType == .lunar && hasLeapMonth(forLunarYear: input.year)
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("日期类型", selection: $input.calendarType) {
                ForEach(CalendarInputType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Text("提示：若输入为阳历（公历），系统会自动转换为阴历（农历）并保存。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if showLeapMonthToggle {
                Toggle("闰月", isOn: $input.isLeapMonth)
                    .toggleStyle(.switch)
                    .padding(.horizontal, 4)
            }

            HStack(spacing: 8) {
                Picker("年", selection: $input.year) {
                    ForEach(yearRange, id: \.self) { year in
                        Text("\(year)年").tag(year)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("月", selection: $input.month) {
                    ForEach(monthOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                Picker("日", selection: $input.day) {
                    ForEach(dayRange, id: \.self) { day in
                        Text("\(day)日").tag(day)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("小时", selection: $input.hour) {
                    ForEach(0...23, id: \.self) { hour in
                        Text("\(hour)时").tag(hour)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: input.calendarType) {
            if !showLeapMonthToggle {
                input.isLeapMonth = false
            }
            clampDayIfNeeded()
        }
        .onChange(of: input.year) {
            if !showLeapMonthToggle {
                input.isLeapMonth = false
            }
            clampDayIfNeeded()
        }
        .onChange(of: input.month) {
            clampDayIfNeeded()
        }
        .onChange(of: input.isLeapMonth) {
            clampDayIfNeeded()
        }
        .onChange(of: input.day) {
            if let validationError = validate(input) {
                errorMessage = validationError
            } else {
                errorMessage = nil
            }
        }
    }

    private func clampDayIfNeeded() {
        let maxDay = daysInMonth(for: input)
        if input.day > maxDay {
            input.day = maxDay
        }
    }
}

private struct BirthLocationStep: View {
    @Binding var query: String
    let suggestions: [GeoLocationSuggestion]
    @Binding var selectedLocation: GeoLocationSuggestion?
    let isSearching: Bool
    @Binding var showHelp: Bool
    let longitudeOffsetMinutes: Int
    let trueSolarComponents: DateComponents?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("出生地")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            TextField("输入省市区或详细地址，例如：上海徐汇区", text: $query)
                .textFieldStyle(.roundedBorder)

            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在搜索地点...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(suggestions) { item in
                            Button {
                                selectedLocation = item
                                query = item.displayAddress
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name.isEmpty ? item.displayAddress : item.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(item.displayAddress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(selectedLocation?.id == item.id ? Color.purple.opacity(0.12) : Color(.secondarySystemBackground))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if let selectedLocation {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选择：\(selectedLocation.displayAddress)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("经度：\(String(format: "%.4f", selectedLocation.longitude))，纬度：\(String(format: "%.4f", selectedLocation.latitude))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("时区：\(selectedLocation.timezoneID)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("请选择一个可匹配的地点。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("与东经 120 度差值：\(longitudeOffsetMinutes >= 0 ? "+" : "")\(longitudeOffsetMinutes) 分钟")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let trueSolarComponents {
                Text("真太阳时：\(formatDateComponents(trueSolarComponents))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("请先完成出生时间输入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

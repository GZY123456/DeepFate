import SwiftUI

struct CreateProfileSheet: View {
    let provinces: [ProvinceOption]
    let existingProfile: UserProfile?
    let onCreate: (UserProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var step: Int = 0
    @State private var name: String
    @State private var gender: Gender
    @State private var birthInput: BirthInput
    @State private var birthInfo: BirthInfo?
    @State private var errorMessage: String?
    @State private var showLocationHelp = false
    @State private var selection: LocationSelection

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

            let options = provinces.isEmpty ? defaultLocationOptions : provinces
            var initialSelection = LocationSelection.defaultValue
            if let provinceIndex = options.firstIndex(where: { $0.name == profile.location.province }) {
                initialSelection.provinceIndex = provinceIndex
                let cities = options[provinceIndex].cities
                if let cityIndex = cities.firstIndex(where: { $0.name == profile.location.city }) {
                    initialSelection.cityIndex = cityIndex
                    let districts = cities[cityIndex].districts
                    if let districtIndex = districts.firstIndex(where: { $0.name == profile.location.district }) {
                        initialSelection.districtIndex = districtIndex
                    }
                }
            }
            _selection = State(initialValue: initialSelection)
        } else {
            _name = State(initialValue: "")
            _gender = State(initialValue: .female)
            _birthInput = State(initialValue: BirthInput.defaultValue)
            _birthInfo = State(initialValue: nil)
            _selection = State(initialValue: LocationSelection.defaultValue)
        }
    }

    private var currentProvinces: [ProvinceOption] {
        provinces.isEmpty ? defaultLocationOptions : provinces
    }

    private var selectedProvince: ProvinceOption {
        currentProvinces[safe: selection.provinceIndex] ?? currentProvinces[0]
    }

    private var selectedCity: CityOption {
        selectedProvince.cities[safe: selection.cityIndex] ?? selectedProvince.cities[0]
    }

    private var selectedDistrict: DistrictOption {
        selectedCity.districts[safe: selection.districtIndex] ?? selectedCity.districts[0]
    }

    private var longitudeOffsetMinutes: Int {
        let offset = (selectedDistrict.longitude - 120.0) * 4.0
        return Int(offset.rounded())
    }

    private var trueSolarComponents: DateComponents? {
        guard let birthInfo else { return nil }
        return computeTrueSolarComponents(from: birthInfo.solarComponents, longitude: selectedDistrict.longitude)
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
                        provinces: currentProvinces,
                        selection: $selection,
                        showHelp: $showLocationHelp,
                        selectedDistrict: selectedDistrict,
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
        .onChange(of: selection.provinceIndex) { _ in
            selection.cityIndex = 0
            selection.districtIndex = 0
        }
        .onChange(of: selection.cityIndex) { _ in
            selection.districtIndex = 0
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
            return true
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
                  let trueSolarComponents else {
                errorMessage = "无法计算真太阳时，请确认出生时间与地点。"
                return
            }
            let location = BirthLocation(
                province: selectedProvince.name,
                city: selectedCity.name,
                district: selectedDistrict.name,
                longitude: selectedDistrict.longitude
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
        .onChange(of: input.calendarType) { _ in
            if !showLeapMonthToggle {
                input.isLeapMonth = false
            }
            clampDayIfNeeded()
        }
        .onChange(of: input.year) { _ in
            if !showLeapMonthToggle {
                input.isLeapMonth = false
            }
            clampDayIfNeeded()
        }
        .onChange(of: input.month) { _ in
            clampDayIfNeeded()
        }
        .onChange(of: input.isLeapMonth) { _ in
            clampDayIfNeeded()
        }
        .onChange(of: input.day) { _ in
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
    let provinces: [ProvinceOption]
    @Binding var selection: LocationSelection
    @Binding var showHelp: Bool
    let selectedDistrict: DistrictOption
    let longitudeOffsetMinutes: Int
    let trueSolarComponents: DateComponents?

    private var provinceIndex: Int {
        min(selection.provinceIndex, provinces.count - 1)
    }

    private var cities: [CityOption] {
        provinces[provinceIndex].cities
    }

    private var cityIndex: Int {
        min(selection.cityIndex, cities.count - 1)
    }

    private var districts: [DistrictOption] {
        cities[cityIndex].districts
    }

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

            HStack(spacing: 8) {
                Picker("省", selection: $selection.provinceIndex) {
                    ForEach(provinces.indices, id: \.self) { index in
                        Text(provinces[index].name).tag(index)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("市", selection: $selection.cityIndex) {
                    ForEach(cities.indices, id: \.self) { index in
                        Text(cities[index].name).tag(index)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("区/县", selection: $selection.districtIndex) {
                    ForEach(districts.indices, id: \.self) { index in
                        Text(districts[index].name).tag(index)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }

            Text("经度：\(String(format: "%.2f", selectedDistrict.longitude)) 度")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

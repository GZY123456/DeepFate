import Foundation

enum CalendarInputType: String, CaseIterable, Identifiable, Codable {
    case solar = "阳历"
    case lunar = "阴历"

    var id: String { rawValue }
}

enum Gender: String, CaseIterable, Identifiable, Codable {
    case male = "男"
    case female = "女"
    case other = "其他"

    var id: String { rawValue }
}

struct BirthInput: Equatable, Codable {
    var calendarType: CalendarInputType
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var isLeapMonth: Bool

    static var defaultValue: BirthInput {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        return BirthInput(
            calendarType: .solar,
            year: calendar.component(.year, from: now),
            month: calendar.component(.month, from: now),
            day: calendar.component(.day, from: now),
            hour: calendar.component(.hour, from: now),
            isLeapMonth: false
        )
    }
}

struct BirthInfo: Equatable, Codable {
    let inputType: CalendarInputType
    let solarComponents: DateComponents
    let lunarComponents: DateComponents
}

struct BirthLocation: Equatable, Codable {
    let province: String
    let city: String
    let district: String
    let longitude: Double
}

struct UserProfile: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let gender: Gender
    let birthInfo: BirthInfo
    let location: BirthLocation
    let trueSolarComponents: DateComponents
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        gender: Gender,
        birthInfo: BirthInfo,
        location: BirthLocation,
        trueSolarComponents: DateComponents,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.gender = gender
        self.birthInfo = birthInfo
        self.location = location
        self.trueSolarComponents = trueSolarComponents
        self.createdAt = createdAt
    }
}

struct LocationSelection: Equatable {
    var provinceIndex: Int
    var cityIndex: Int
    var districtIndex: Int

    static var defaultValue: LocationSelection {
        LocationSelection(provinceIndex: 0, cityIndex: 0, districtIndex: 0)
    }
}

struct ProvinceOption: Identifiable, Codable {
    let id: UUID
    let name: String
    let cities: [CityOption]

    init(id: UUID = UUID(), name: String, cities: [CityOption]) {
        self.id = id
        self.name = name
        self.cities = cities
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case cities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        cities = try container.decode([CityOption].self, forKey: .cities)
        id = UUID()
    }
}

struct CityOption: Identifiable, Codable {
    let id: UUID
    let name: String
    let districts: [DistrictOption]

    init(id: UUID = UUID(), name: String, districts: [DistrictOption]) {
        self.id = id
        self.name = name
        self.districts = districts
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case districts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        districts = try container.decode([DistrictOption].self, forKey: .districts)
        id = UUID()
    }
}

struct DistrictOption: Identifiable, Codable {
    let id: UUID
    let name: String
    let longitude: Double

    init(id: UUID = UUID(), name: String, longitude: Double) {
        self.id = id
        self.name = name
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        longitude = try container.decode(Double.self, forKey: .longitude)
        id = UUID()
    }
}

let yearRange = 1900...2100

let lunarMonthNames = [
    "正月", "二月", "三月", "四月", "五月", "六月",
    "七月", "八月", "九月", "十月", "冬月", "腊月"
]

let solarMonthNames = (1...12).map { "\($0)月" }

let defaultLocationOptions: [ProvinceOption] = [
    ProvinceOption(
        name: "北京",
        cities: [
            CityOption(name: "北京市", districts: [
                DistrictOption(name: "东城区", longitude: 116.4167),
                DistrictOption(name: "朝阳区", longitude: 116.4864),
                DistrictOption(name: "海淀区", longitude: 116.3054)
            ])
        ]
    ),
    ProvinceOption(
        name: "上海",
        cities: [
            CityOption(name: "上海市", districts: [
                DistrictOption(name: "黄浦区", longitude: 121.4903),
                DistrictOption(name: "浦东新区", longitude: 121.5447),
                DistrictOption(name: "徐汇区", longitude: 121.4375)
            ])
        ]
    ),
    ProvinceOption(
        name: "广东",
        cities: [
            CityOption(name: "深圳市", districts: [
                DistrictOption(name: "南山区", longitude: 113.9304),
                DistrictOption(name: "福田区", longitude: 114.0557),
                DistrictOption(name: "罗湖区", longitude: 114.1239)
            ]),
            CityOption(name: "广州市", districts: [
                DistrictOption(name: "天河区", longitude: 113.3610),
                DistrictOption(name: "越秀区", longitude: 113.2666),
                DistrictOption(name: "海珠区", longitude: 113.2620)
            ])
        ]
    )
]

func validate(_ input: BirthInput) -> String? {
    if input.year < 1900 || input.year > 2100 {
        return "请输入正确的年份（1900-2100）。"
    }
    if !(1...12).contains(input.month) {
        return "请输入正确的月份（1-12）。"
    }
    if !(1...31).contains(input.day) {
        return "请输入正确的日期（1-31）。"
    }
    if !(0...23).contains(input.hour) {
        return "请输入正确的小时（0-23）。"
    }
    return nil
}

func daysInMonth(for input: BirthInput) -> Int {
    let calendar: Calendar = (input.calendarType == .solar)
        ? Calendar(identifier: .gregorian)
        : Calendar(identifier: .chinese)

    var components = DateComponents()
    components.year = input.year
    components.month = input.month
    components.day = 1
    components.hour = 0
    components.minute = 0
    if input.calendarType == .lunar {
        if #available(iOS 17.0, *) {
            components.isLeapMonth = input.isLeapMonth
        }
    }
    components.calendar = calendar

    guard let date = calendar.date(from: components),
          let range = calendar.range(of: .day, in: .month, for: date) else {
        return 31
    }
    return range.count
}

func hasLeapMonth(forLunarYear year: Int) -> Bool {
    let chinese = Calendar(identifier: .chinese)
    var startComponents = DateComponents()
    startComponents.calendar = chinese
    startComponents.year = year
    startComponents.month = 1
    startComponents.day = 1

    guard let startDate = chinese.date(from: startComponents),
          let range = chinese.range(of: .month, in: .year, for: startDate) else {
        return false
    }
    return range.count > 12
}

func makeBirthInfo(from input: BirthInput) -> BirthInfo? {
    let gregorian = Calendar(identifier: .gregorian)
    let chinese = Calendar(identifier: .chinese)

    var baseComponents = DateComponents()
    baseComponents.year = input.year
    baseComponents.month = input.month
    baseComponents.day = input.day
    baseComponents.hour = input.hour
    baseComponents.minute = 0

    let baseCalendar = (input.calendarType == .solar) ? gregorian : chinese
    baseComponents.calendar = baseCalendar
    if input.calendarType == .lunar {
        if #available(iOS 17.0, *) {
            baseComponents.isLeapMonth = input.isLeapMonth
        }
    }

    guard let date = baseCalendar.date(from: baseComponents) else {
        return nil
    }

    let solar = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let lunar = chinese.dateComponents([.year, .month, .day, .hour, .minute], from: date)

    return BirthInfo(inputType: input.calendarType, solarComponents: solar, lunarComponents: lunar)
}

func computeTrueSolarComponents(from solar: DateComponents, longitude: Double) -> DateComponents? {
    var base = solar
    base.calendar = Calendar(identifier: .gregorian)
    if base.minute == nil {
        base.minute = 0
    }
    guard let baseDate = base.calendar?.date(from: base) else {
        return nil
    }
    let offsetMinutes = Int(((longitude - 120.0) * 4.0).rounded())
    guard let adjusted = Calendar(identifier: .gregorian)
        .date(byAdding: .minute, value: offsetMinutes, to: baseDate) else {
        return nil
    }
    return Calendar(identifier: .gregorian)
        .dateComponents([.year, .month, .day, .hour, .minute], from: adjusted)
}

func formatDateComponents(_ components: DateComponents) -> String {
    let year = components.year ?? 0
    let month = components.month ?? 0
    let day = components.day ?? 0
    let hour = components.hour ?? 0
    let minute = components.minute ?? 0
    return String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

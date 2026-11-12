import Foundation

public struct AudioInputSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sourceKey: String
    public let name: String
    public let transport: String
    public let badge: String
    public let isDefault: Bool

    private enum CodingKeys: String, CodingKey {
        case id, sourceKey, name, transport, badge, isDefault
    }

    public init(
        id: String,
        sourceKey: String? = nil,
        name: String,
        transport: String = "external",
        badge: String = "音频输入",
        isDefault: Bool = false
    ) {
        self.id = id
        self.sourceKey = sourceKey ?? "input:\(id)"
        self.name = name
        self.transport = transport
        self.badge = badge
        self.isDefault = isDefault
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decode(String.self, forKey: .id)
        id = decodedId
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey) ?? "input:\(decodedId)"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? decodedId
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? "external"
        badge = try c.decodeIfPresent(String.self, forKey: .badge) ?? "音频输入"
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

public struct CaptureStudioSnapshot: Codable, Equatable, Sendable {
    public let selectedSource: String
    public let selectedInputId: String
    public let selectedLabel: String
    public let selectedBadge: String
    public let selectionMode: String
    public let activeSource: String?
    public let canStart: Bool
    public let inputs: [AudioInputSnapshot]

    private enum CodingKeys: String, CodingKey {
        case selectedSource, selectedInputId, selectedLabel, selectedBadge
        case selectionMode, activeSource, canStart, inputs
    }

    public static let empty = CaptureStudioSnapshot(
        selectedSource: "system_default",
        selectedInputId: "",
        selectedLabel: "系统默认麦克风",
        selectedBadge: "系统默认",
        selectionMode: "auto",
        activeSource: nil,
        canStart: true,
        inputs: []
    )

    public init(
        selectedSource: String,
        selectedInputId: String,
        selectedLabel: String,
        selectedBadge: String,
        selectionMode: String,
        activeSource: String?,
        canStart: Bool,
        inputs: [AudioInputSnapshot]
    ) {
        self.selectedSource = selectedSource
        self.selectedInputId = selectedInputId
        self.selectedLabel = selectedLabel
        self.selectedBadge = selectedBadge
        self.selectionMode = selectionMode
        self.activeSource = activeSource
        self.canStart = canStart
        self.inputs = inputs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSource = try c.decodeIfPresent(String.self, forKey: .selectedSource) ?? "system_default"
        selectedInputId = try c.decodeIfPresent(String.self, forKey: .selectedInputId) ?? ""
        selectedLabel = try c.decodeIfPresent(String.self, forKey: .selectedLabel) ?? "系统默认麦克风"
        selectedBadge = try c.decodeIfPresent(String.self, forKey: .selectedBadge) ?? "系统默认"
        selectionMode = try c.decodeIfPresent(String.self, forKey: .selectionMode) ?? "auto"
        activeSource = try c.decodeIfPresent(String.self, forKey: .activeSource)
        canStart = try c.decodeIfPresent(Bool.self, forKey: .canStart) ?? true
        inputs = try c.decodeIfPresent([AudioInputSnapshot].self, forKey: .inputs) ?? []
    }
}

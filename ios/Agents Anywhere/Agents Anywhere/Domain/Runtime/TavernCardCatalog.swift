import Foundation

// 酒馆实例的开局契约。字段形状对齐 dsh-bridge-next/src/host/dsh-runtime/tavern.ts：
// 创建会话时 runtimeOptions.tavern = { card, openingId, userName }。
nonisolated struct TavernOpeningSelection: Hashable {
    let card: String
    let openingId: String
    let userName: String

    var runtimeOption: JSONValue {
        .object([
            "card": .string(card),
            "openingId": .string(openingId),
            "userName": .string(userName),
        ])
    }
}

nonisolated struct TavernCardOpening: Decodable, Hashable {
    let id: String
    let text: String
}

nonisolated struct TavernCardScript: Decodable, Hashable {
    let path: String
    let title: String
}

nonisolated struct TavernCard: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let group: String
    let starred: Bool
    let script: TavernCardScript?
    let openings: [TavernCardOpening]?

    var id: String { path }
}

// 精简卡目（catalog.listTavernCards，openings: false）。connector 把它挂在 DSH 类型描述符的
// metadata 上，server 将类型 metadata 原样放进实例行（server/api/v2/device_runtimes.py:678），
// 因此已加载的 V2DeviceRuntime.metadata 即包含它，无需额外请求。
// 能力判定按目录存在与否，不按 provider 名称写死。
nonisolated struct TavernCardCatalog: Decodable, Hashable {
    static let metadataKey = "tavernCardCatalog"

    let workspace: String
    let groups: [String]
    let cards: [TavernCard]

    static func decode(from runtime: V2DeviceRuntime) -> TavernCardCatalog? {
        guard let value = runtime.metadata[metadataKey],
              let data = try? JSONEncoder().encode(value),
              let catalog = try? JSONDecoder().decode(TavernCardCatalog.self, from: data),
              !catalog.workspace.isEmpty,
              !catalog.cards.isEmpty
        else { return nil }
        return catalog
    }

    func cards(in group: String) -> [TavernCard] {
        cards.filter { $0.group == group }
    }

    // 分组顺序以 groups 为准；卡片带有未知分组时补在后面，避免卡片被吞掉。
    var orderedGroups: [String] {
        let known = groups.filter { group in cards.contains { $0.group == group } }
        let extra = Set(cards.map(\.group)).subtracting(known).sorted()
        return known + extra
    }
}

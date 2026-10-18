import Foundation
import Testing
@testable import ClientCore

// 酒馆开局：卡目解析、工作区固定、runtimeOptions.tavern 编码。
@Suite @MainActor struct TavernTests {
    // 工作区取 "/workspace"，与 projects fixture 中的项目一致，
    // 让创建走既有的项目解析路径，测试只覆盖酒馆逻辑。
    private static let catalogJSON: [String: Any] = [
        "workspace": "/workspace",
        "groups": ["原创", "同人"],
        "cards": [
            ["path": "cards/inn.md", "name": "雪夜客栈", "group": "原创", "starred": true,
             "script": ["path": "scripts/inn.json", "title": "客栈脚本"], "openings": NSNull()],
            ["path": "cards/sea.md", "name": "海雾", "group": "同人", "starred": false,
             "script": NSNull(),
             "openings": [["id": "op1", "text": "雾从海面漫上来……"], ["id": "op2", "text": "你推开舱门。"]]],
        ],
    ]

    private func make(_ http: TestHTTPTransport) -> NewSessionModel {
        let connectors = V2ConnectorAPI(transport: http)
        let model = NewSessionModel(scope: .init(serverURL: URL(string: "https://example.test")!, accountID: "one"),
            devices: .init(connectorAPI: connectors), preparation: .init(connectorAPI: connectors),
            creation: .init(sessionAPI: V2SessionAPI(transport: http)), projectAPI: V2ProjectAPI(transport: http),
            defaults: UserDefaults(suiteName: "aa-tests-\(UUID().uuidString)")!)
        if let response: V2ProjectListResponse = try? JSONDecoder().decode(V2ProjectListResponse.self, from: fixtureData("projects")) { model.updateProjects(response.projects) }
        return model
    }

    private func tavernTransport() -> TestHTTPTransport {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("/runtimes") {
                var object = try fixtureObject("runtimes")
                var instance = (object["runtimes"] as! [[String: Any]])[0]
                instance["metadata"] = ["tavernCardCatalog": Self.catalogJSON]
                object["runtimes"] = [instance]
                return try JSONSerialization.data(withJSONObject: object)
            }
            if call.path.hasSuffix("/rti_work") { return try fixtureData("runtime") }
            if call.path.hasSuffix("/create-and-start") { return try fixtureData("session") }
            return try http.defaultResponse(call)
        }
        return http
    }

    private func devices() throws -> [V2Connector] {
        var object = try fixtureObject("connector")
        var device = object["connector"] as! [String: Any]
        device["status"] = "online"
        object["connector"] = device
        let response: V2ConnectorResponse = try decode(object)
        return [response.connector]
    }

    @Test func catalogParsesFromInstanceMetadata() throws {
        var object = try fixtureObject("runtimes")
        var instance = (object["runtimes"] as! [[String: Any]])[0]
        instance["metadata"] = ["tavernCardCatalog": Self.catalogJSON]
        object["runtimes"] = [instance]
        let response: V2DeviceRuntimeListResponse = try decode(object)
        let runtime = try #require(response.runtimes.first)
        let catalog = try #require(TavernCardCatalog.decode(from: runtime))
        #expect(catalog.workspace == "/workspace")
        #expect(catalog.cards.count == 2)
        #expect(catalog.orderedGroups == ["原创", "同人"])
        #expect(catalog.cards(in: "原创").first?.starred == true)
        #expect(catalog.cards.first { $0.path == "cards/sea.md" }?.openings?.map(\.id) == ["op1", "op2"])
        #expect(catalog.cards.first { $0.path == "cards/inn.md" }?.openings == nil)

        let plain: V2DeviceRuntimeListResponse = try fixture("runtimes")
        #expect(TavernCardCatalog.decode(from: plain.runtimes[0]) == nil, "No catalog metadata means no tavern capability.")
    }

    @Test func tavernTargetPinsWorkspaceAndRejectsManualSelection() async throws {
        let http = tavernTransport(); let model = make(http)
        await model.refresh(connectors: try devices())
        #expect(model.tavernCatalog != nil)
        #expect(model.hasTavernOpeningFlow)
        #expect(model.workspace == "/workspace")
        #expect(model.project?.id == "project", "The pinned workspace resolves its project through the normal path.")
        #expect(!model.selectWorkspace("/other/path"))
        #expect(!model.selectProject("project"))
        #expect(model.workspace == "/workspace")
    }

    @Test func tavernOpeningCreationSendsRuntimeOptions() async throws {
        let http = tavernTransport(); let model = make(http)
        model.draft.text = "推开客栈的门"
        await model.refresh(connectors: try devices())
        #expect(model.canCreate)
        let session = await model.create(text: "推开客栈的门",
            tavern: TavernOpeningSelection(card: "cards/inn.md", openingId: "op1", userName: "林克"))
        #expect(session?.id == "session")
        let request = try #require(http.calls.first { $0.path.hasSuffix("create-and-start") })
        let tavern = try #require(request.body?["runtimeOptions"]?["tavern"])
        #expect(tavern["card"]?.stringValue == "cards/inn.md")
        #expect(tavern["openingId"]?.stringValue == "op1")
        #expect(tavern["userName"]?.stringValue == "林克")
        #expect(request.body?["cwd"]?.stringValue == "/workspace")
    }

    @Test func plainCreationSendsEmptyRuntimeOptions() async throws {
        let http = tavernTransport(); let model = make(http)
        model.draft.text = "普通消息"
        await model.refresh(connectors: try devices())
        let session = await model.create(text: "普通消息")
        #expect(session?.id == "session")
        let request = try #require(http.calls.first { $0.path.hasSuffix("create-and-start") })
        let options = request.body?["runtimeOptions"]
        if case .object(let dict)? = options {
            #expect(dict.isEmpty)
        } else {
            Issue.record("Plain creation must still send an (empty) runtimeOptions object.")
        }
    }
}

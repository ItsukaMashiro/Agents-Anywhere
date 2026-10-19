import Foundation

struct V2SessionCreationService {
    let sessionAPI: any V2SessionAPIProtocol

    /// Encodes initial attachments inline because no session-scoped upload resource exists before creation.
    func createAndStart(
        connectorId: V2ConnectorID,
        projectId: String,
        runtime: V2RuntimeID,
        runtimeId: V2RuntimeID? = nil,
        title: String?,
        cwd: String?,
        content: String,
        selections: [V2RuntimeSelectionScope: V2SelectionID],
        runtimeOptions: [String: JSONValue] = [:],
        attachments: [V2LocalAttachment],
        clientMessageId: String
    ) async throws -> V2SessionCreateResponse {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 契约 A：tavern 开局允许空 content（开场白即首条消息）；其余创建仍要求文本或附件。
        if normalizedContent.isEmpty, attachments.isEmpty, runtimeOptions["tavern"] == nil {
            throw V2BusinessError.emptyMessage
        }
        if attachments.count > 10 {
            throw V2BusinessError.tooManyAttachments(maximum: 10)
        }
        let inlineAttachments = try attachments.map { attachment in
            if attachment.data.isEmpty {
                throw V2BusinessError.emptyAttachment(name: attachment.name)
            }
            return V2InlineAttachment(
                fileId: attachment.fileId,
                name: attachment.name,
                mediaType: attachment.mediaType,
                size: attachment.data.count,
                sha256: attachment.sha256,
                contentBase64: attachment.data.base64EncodedString()
            )
        }
        return try await sessionAPI.createAndStartSession(
            request: V2SessionCreateAndStartRequest(
                connectorId: connectorId,
                projectId: projectId,
                runtime: runtime,
                runtimeId: runtimeId,
                title: title,
                cwd: cwd,
                content: normalizedContent,
                selections: selections,
                runtimeOptions: runtimeOptions,
                attachments: inlineAttachments,
                clientMessageId: clientMessageId
            )
        )
    }

    func bindExisting(
        connectorId: V2ConnectorID,
        projectId: String,
        runtime: V2RuntimeID,
        runtimeId: V2RuntimeID? = nil,
        externalSessionId: String,
        title: String?,
        cwd: String?,
        selections: [V2RuntimeSelectionScope: V2SelectionID]
    ) async throws -> V2SessionCreateResponse {
        try await sessionAPI.createSession(
            request: V2SessionCreateRequest(
                connectorId: connectorId,
                projectId: projectId,
                runtime: runtime,
                runtimeId: runtimeId,
                externalSessionId: externalSessionId,
                title: title,
                cwd: cwd,
                selections: selections
            )
        )
    }
}

import SwiftUI

// 酒馆开局流程：选卡 →（可选）开场白轮播 → 用户名与第一句话 → 创建会话。
// 创建时 runtimeOptions.tavern = { card, openingId, userName }，与
// dsh-bridge-next/src/host/dsh-runtime/tavern.ts 的 TavernOpening 对齐。
struct TavernOpeningSheet: View {
    @Bindable var model: NewSessionModel
    let onCreated: (V2SessionMeta) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [TavernStep] = []
    @State private var search = ""
    // 精简卡目不携带 openings；点卡时按需拉取，结果按卡 path 缓存，失败/空保持降级。
    @State private var openingsCache: [String: [TavernCardOpening]] = [:]
    @State private var loadingCardPath: String?
    // 分类默认折叠，只显示组名；点开的组集合按组名记忆。搜索时命中组自动展开。
    @State private var expandedGroups: Set<String> = []
    @Environment(\.colorScheme) private var colorScheme

    private enum TavernStep: Hashable {
        case opening(TavernCard, openings: [TavernCardOpening])
        case details(TavernCard, openingId: String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            cardList
                .navigationTitle(String(localized: "选择开局卡片"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { SheetCloseToolbar(disabled: false) { dismiss() } }
                .searchable(text: $search, prompt: String(localized: "搜索卡片"))
                .navigationDestination(for: TavernStep.self) { step in
                    switch step {
                    case .opening(let card, let openings):
                        TavernOpeningPager(card: card, openings: openings) { openingID in
                            path.append(.details(card, openingId: openingID))
                        }
                    case .details(let card, let openingID):
                        TavernGameDetailsView(model: model, card: card, openingId: openingID,
                            onCreated: { session in
                                // 开局成功后整张向导关闭，会话页由调用方接管。
                                onCreated(session)
                                dismiss()
                            })
                    }
                }
        }
        .appSheetPresentation(.expanded)
    }

    private var catalog: TavernCardCatalog? { model.tavernCatalog }

    private var filteredCards: [TavernCard] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let catalog else { return [] }
        guard !query.isEmpty else { return catalog.cards }
        return catalog.cards.filter { card in
            card.name.localizedCaseInsensitiveContains(query) ||
            card.group.localizedCaseInsensitiveContains(query)
        }
    }

    private var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func expansionBinding(_ group: String) -> Binding<Bool> {
        Binding(
            get: { isSearching || expandedGroups.contains(group) },
            set: { open in
                if open { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
            }
        )
    }

    private var cardList: some View {
        List {
            if catalog == nil {
                ContentUnavailableView(String(localized: "这张实例没有可用的卡片"), appSymbol: "menucard")
            } else {
                ForEach(catalog!.orderedGroups, id: \.self) { group in
                    let cards = filteredCards.filter { $0.group == group }
                        .sorted { ($0.starred ? 0 : 1, $0.name) < ($1.starred ? 0 : 1, $1.name) }
                    if !cards.isEmpty {
                        Section(isExpanded: expansionBinding(group)) {
                            ForEach(cards) { card in
                                Button {
                                    select(card)
                                } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(card.name).font(.body.weight(.medium))
                                            if let script = card.script, !script.title.isEmpty {
                                                Text(script.title).font(.footnote).foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        if card.starred {
                                            Image(systemName: "star.fill").font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        if loadingCardPath == card.path {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "chevron.right").font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .contentShape(.rect)
                                }
                                .accessibilityIdentifier("tavern.card.\(card.path)")
                            }
                        } header: {
                            Text(group.isEmpty ? String(localized: "未分组") : group)
                        }
                    }
                }
            }
        }
    }

    // 进入某卡：先按需拉取该卡开场白（同卡结果缓存）。非空进轮播；
    // 失败或为空保持现有降级——直接进开局设置，openingId 传空串。
    private func select(_ card: TavernCard) {
        if let openings = card.openings, !openings.isEmpty {
            path.append(.opening(card, openings: openings))
            return
        }
        if let cached = openingsCache[card.path] {
            path.append(cached.isEmpty ? .details(card, openingId: "") : .opening(card, openings: cached))
            return
        }
        guard loadingCardPath == nil else { return }
        loadingCardPath = card.path
        Task {
            let openings = await model.fetchTavernOpenings(for: card)
            openingsCache[card.path] = openings
            loadingCardPath = nil
            path.append(openings.isEmpty ? .details(card, openingId: "") : .opening(card, openings: openings))
        }
    }
}

// 开场白轮播：逐条翻阅，也可跳过使用默认开场白（openingId 传空串）。
private struct TavernOpeningPager: View {
    let card: TavernCard
    let openings: [TavernCardOpening]
    let onChoose: (_ openingID: String) -> Void
    @State private var index = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(openings[index].text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            HStack(spacing: 16) {
                Button {
                    index = (index - 1 + openings.count) % openings.count
                } label: { Image(systemName: "chevron.left") }
                    .disabled(openings.count < 2)
                Text("\(index + 1) / \(openings.count)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    index = (index + 1) % openings.count
                } label: { Image(systemName: "chevron.right") }
                    .disabled(openings.count < 2)
            }
            .padding(.vertical, 14)
            VStack(spacing: 10) {
                Button(String(localized: "使用这条开场白")) { onChoose(openings[index].id) }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primaryControlBackground(colorScheme))
                    .foregroundStyle(AppTheme.primaryControlForeground(colorScheme))
                Button(String(localized: "使用默认开场白")) { onChoose("") }
            }
            .padding(.bottom, 16)
        }
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// 用户名与第一句话。第一句话直接写入草稿（与输入框同一来源），
// 取消时保留，创建成功后由 create() 清空。
private struct TavernGameDetailsView: View {
    @Bindable var model: NewSessionModel
    let card: TavernCard
    let openingId: String
    let onCreated: (V2SessionMeta) -> Void
    @State private var userName = ""
    @State private var isCreating = false
    @State private var creationError: String?
    @Environment(\.colorScheme) private var colorScheme

    private var firstLine: Binding<String> {
        Binding(get: { model.draft.text }, set: { model.draft.text = $0; model.scheduleDraftSave() })
    }

    private var canStart: Bool {
        model.canStartTavern
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "卡片")) { Text(card.name) }
                if !openingId.isEmpty {
                    LabeledContent(String(localized: "开场白")) { Text(String(localized: "已选择")).foregroundStyle(.secondary) }
                } else {
                    LabeledContent(String(localized: "开场白")) { Text(String(localized: "默认")).foregroundStyle(.secondary) }
                }
            }
            Section {
                TextField(String(localized: "用户名"), text: $userName, prompt: Text(String(localized: "你")))
                    .textContentType(.name)
            } header: {
                Text(String(localized: "你的角色"))
            } footer: {
                Text(String(localized: "开场白与后续剧情会用这个名字称呼你。"))
            }
            Section {
                TextField(String(localized: "你的第一句话"), text: firstLine, axis: .vertical)
                    .lineLimit(1...6)
            } header: {
                Text(String(localized: "第一句话"))
            } footer: {
                if let creationError {
                    Text(creationError).foregroundStyle(.red)
                } else {
                    Text(String(localized: "开局后会作为你的第一条消息发送；留空则直接使用开场白开局。"))
                }
            }
            Section {
                Button {
                    start()
                } label: {
                    HStack {
                        if isCreating { ProgressView().controlSize(.small) }
                        Text(String(localized: "开始游戏")).frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryControlBackground(colorScheme))
                .foregroundStyle(AppTheme.primaryControlForeground(colorScheme))
                .disabled(!canStart || isCreating)
                .accessibilityIdentifier("tavern.start")
            }
        }
        .navigationTitle(String(localized: "开局设置"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isCreating)
    }

    private func start() {
        guard canStart, !isCreating else { return }
        isCreating = true; creationError = nil
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = TavernOpeningSelection(card: card.path, openingId: openingId,
            userName: trimmed.isEmpty ? String(localized: "你") : trimmed)
        Task {
            let session = await model.create(text: model.draft.text, tavern: selection)
            isCreating = false
            if let session {
                onCreated(session)
            } else {
                creationError = model.error ?? String(localized: "创建失败，请检查设备连接后重试。")
            }
        }
    }
}

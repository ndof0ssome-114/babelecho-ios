import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private enum Page: Hashable { case workspace, history, settings }
private enum Panel: String, CaseIterable { case transcript, summary, minutes, ask, stats }
private struct SharedFile: Identifiable { let id = UUID(); let url: URL }
private struct SeekRequest { let id = UUID(); let milliseconds: Int }

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: Page = .workspace
    @State private var showConsent = false
    @State private var showScreenConsent = false

    var body: some View {
        TabView(selection: $page) {
            NavigationStack { WorkspaceView(showConsent: $showConsent, showScreenConsent: $showScreenConsent) }
                .tabItem { Label(t("工作台", "ワークスペース", "Workspace"), systemImage: "waveform") }
                .tag(Page.workspace)
            NavigationStack { HistoryView(open: { page = .workspace }) }
                .tabItem { Label(t("历史", "履歴", "History"), systemImage: "clock.arrow.circlepath") }
                .tag(Page.history)
            NavigationStack { SettingsView() }
                .tabItem { Label(t("设置", "設定", "Settings"), systemImage: "gearshape") }
                .tag(Page.settings)
        }
        .alert(t("录音与数据处理", "録音とデータ処理", "Recording and data use"), isPresented: $showConsent) {
            Button(t("同意并开始", "同意して開始", "Agree and start")) { Task { await model.startRecording() } }
            Button(t("取消", "キャンセル", "Cancel"), role: .cancel) { }
        } message: {
            Text(t("请先确认参会者已同意录音。音频保存在本机；启用实时识别后，片段会发送至你配置的 ASR 地址。摘要、翻译、问答，以及停止录音时自动生成的纪要，会把文字发送至你配置的文本模型。", "参加者の録音同意を確認してください。音声は端末に保存されます。リアルタイム認識を有効にすると設定した ASR に音声を送信します。要約・翻訳・質問応答、および録音停止時に自動作成される議事録は、設定したテキストモデルに文字を送信します。", "Confirm participants have agreed to recording. Audio stays on this device. Live transcription sends chunks to your configured ASR endpoint. Summaries, translations, Q&A, and minutes automatically generated when recording stops send text to your configured text model."))
        }
        .alert(t("录制屏幕声音", "画面の音声を録音", "Record screen audio"), isPresented: $showScreenConsent) {
            Button(t("打开系统选择器", "システム選択画面を開く", "Open system picker")) { model.startScreenCapture() }
            Button(t("取消", "キャンセル", "Cancel"), role: .cancel) { }
        } message: {
            Text(t("请先确认参会者同意。iOS 27 会显示系统屏幕录制选择器；录制期间屏幕画面和系统声音会临时写入视频文件，结束后提取声音保存为本机 WAV 并删除临时视频。此操作不会自动上传音频。", "参加者の同意を確認してください。iOS 27 のシステム選択画面で許可すると、画面とシステム音声を一時的な動画に記録します。終了後、音声を端末内の WAV に変換して一時動画を削除します。自動アップロードはしません。", "Confirm participants' consent. The iOS 27 system picker controls capture. Screen video and system audio are stored temporarily; after stopping, the audio is saved locally as WAV and the temporary video is deleted. Nothing is uploaded automatically."))
        }
        .alert(t("提示", "お知らせ", "Notice"), isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) { Button("OK") { model.message = nil } } message: { Text(model.message ?? "") }
    }

    private func t(_ zh: String, _ ja: String, _ en: String) -> String {
        L10n.text(model.settings.uiLanguage, zh, ja, en)
    }
}

private struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var showConsent: Bool
    @Binding var showScreenConsent: Bool
    @State private var panel: Panel = .transcript
    @State private var question = ""
    @State private var title = ""
    @State private var sharedFile: SharedFile?
    @State private var showImporter = false
    @State private var showImportChoice = false
    @State private var pendingImports: [URL] = []
    @State private var seekRequest: SeekRequest?
    @State private var renameSource: String?
    @State private var renameDraft = ""
    /// The sentence whose speaker was tapped, for "this sentence only" (desktop set-segment-speaker).
    @State private var renameSegment: UUID?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                recordingCard
                if let meeting = model.selected {
                    meetingCard(meeting)
                    panelPicker
                    copyControl(meeting)
                    content(meeting)
                    AudioPlayback(url: meeting.state == "stopped" ? model.audioURL(for: meeting.id) : nil,
                                  language: model.settings.uiLanguage, seekRequest: seekRequest)
                    exportCard(meeting)
                } else {
                    card { Text(t("开始录音后，会议会保存在这里。", "録音するとここに会議が保存されます。", "Your meetings will appear here after recording.")) }
                }
            }
            .padding()
            // Keep a readable column on iPad; no effect at iPhone widths.
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.05, green: 0.08, blue: 0.15), Color(red: 0.08, green: 0.13, blue: 0.19)]
                : [Color(red: 0.91, green: 0.94, blue: 1), .white, Color(red: 0.91, green: 0.98, blue: 0.98)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ).ignoresSafeArea())
        .navigationTitle("Babel Echo")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { title = model.selected?.title ?? "" }
        .onChange(of: model.selectedID) { _, _ in title = model.selected?.title ?? "" }
        .sheet(item: $sharedFile) { ActivitySheet(url: $0.url) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                pendingImports = urls
                showImportChoice = !urls.isEmpty
            case .failure(let error): model.message = error.localizedDescription
            }
        }
        .alert(t("导入音视频文件", "音声・動画ファイルを読み込む", "Import media files"), isPresented: $showImportChoice) {
            Button(t("仅本地导入", "端末内にのみ保存", "Import locally")) {
                let urls = pendingImports; pendingImports = []
                Task { await model.importMedia(urls, processAI: false) }
            }
            Button(t("导入并使用模型处理", "読み込み後にモデルで処理", "Import and process with models")) {
                let urls = pendingImports; pendingImports = []
                Task { await model.importMedia(urls, processAI: true) }
            }
            Button(t("取消", "キャンセル", "Cancel"), role: .cancel) { pendingImports = [] }
        } message: {
            Text(t("选择模型处理时，音频会发送至你配置的 ASR，转写文字可能发送至文本模型生成纪要。仅本地导入不会联网。", "モデル処理を選ぶと音声は設定した ASR に、文字は議事録作成のためテキストモデルに送信されます。端末内のみなら通信しません。", "Model processing sends audio to your configured ASR and may send text to your text model for minutes. Local-only import makes no network request."))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("BrandIcon").resizable().scaledToFit().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading) {
                Text(t("巴别回声", "バベルエコー", "Babel Echo")).font(.title2.bold()).foregroundStyle(.primary)
                Text(t("本地优先的 AI 会议工作台", "ローカル優先の AI 会議ワークスペース", "Local first AI meeting workspace"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var panelPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Panel.allCases, id: \.self) { item in
                    Button { panel = item } label: {
                        Text(panelName(item))
                            .font(.subheadline.weight(panel == item ? .semibold : .regular))
                            .frame(minWidth: 64, minHeight: 44)
                            .foregroundStyle(panel == item ? Color.white : Color.primary)
                            .background(panel == item ? Color.indigo : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(panelName(item))
                    .accessibilityIdentifier("panel-" + item.rawValue)
                    .accessibilityAddTraits(panel == item ? .isSelected : [])
                }
            }
            .padding(4)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("content-panels")
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
    }

    private var recordingCard: some View {
        card {
            HStack {
                Label(model.isRecording ? (model.isPaused ? t("已暂停", "一時停止", "Paused") : t("录音中", "録音中", "Recording")) : t("准备录音", "録音の準備", "Ready to record"), systemImage: model.isRecording ? "record.circle.fill" : "mic")
                    .font(.headline)
                Spacer()
                if model.isRecording { Text(String(format: "%02d:%02d", model.recordingDurationMs / 60_000, model.recordingDurationMs / 1000 % 60)).font(.caption.monospacedDigit()) }
            }
            ProgressView(value: Double(min(1, model.level * 10))).tint(.cyan)
            Text(t("麦克风可直接录音；iOS 27 另支持经系统授权录制屏幕声音。", "マイク録音に加え、iOS 27 ではシステムの許可を得て画面の音声を録音できます。", "Record the microphone directly, or capture screen audio with system consent on iOS 27."))
                .font(.caption).foregroundStyle(.secondary)
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())) {
                if model.isRecording {
                    Button(model.isPaused ? t("继续", "再開", "Resume") : t("暂停", "一時停止", "Pause")) { model.pauseOrResume() }
                        .buttonStyle(.bordered)
                    Button(t("结束录音", "録音を終了", "Stop recording"), role: .destructive) { Task { await model.stopRecording() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { showConsent = true } label: {
                        Label(t("开始录音", "録音を開始", "Start recording"), systemImage: "mic.fill")
                    }.buttonStyle(.borderedProminent).disabled(!model.canStartCapture)
                    Button { showImporter = true } label: {
                        Label(t("导入文件", "ファイルを読み込む", "Import file"), systemImage: "square.and.arrow.down")
                    }.buttonStyle(.bordered).disabled(!model.canStartCapture)
                }
                if model.finishing { ProgressView() }
            }
            #if !targetEnvironment(simulator)
            if #available(iOS 27.0, *) {
                if model.isScreenCapturing {
                    Button(t("结束屏幕录制并保存声音", "画面の録画を終了して音声を保存", "Stop screen capture and save audio"), role: .destructive) {
                        Task { await model.stopScreenCapture() }
                    }.buttonStyle(.borderedProminent).disabled(model.screenCaptureFinishing)
                } else if model.isScreenPickerPending {
                    HStack {
                        ProgressView()
                        Text(t("等待系统授权或启动", "システムの許可・開始を待機中", "Waiting for consent or startup"))
                            .font(.caption)
                        Button(t("取消", "キャンセル", "Cancel")) { model.cancelScreenCapturePicker() }
                    }
                } else {
                    Button(t("录制屏幕声音", "画面の音声を録音", "Record screen audio")) { showScreenConsent = true }
                        .buttonStyle(.bordered)
                        .disabled(!model.canStartCapture)
                }
            }
            #endif
            if model.startingRecording { ProgressView(t("正在请求麦克风权限", "マイクの許可を確認中", "Requesting microphone access")) }
            if model.isRecording {
                Text(t("结束时，如已有转写且配置了文本模型，会自动生成纪要。", "文字起こしとモデル設定がある場合、終了時に議事録を自動作成します。", "Stopping generates minutes when a transcript and text model are available.")).font(.caption).foregroundStyle(.secondary)
            }
            #if targetEnvironment(simulator)
            Text(t("系统声音录制需要 iOS 27 真机。", "システム音声の録音には iOS 27 の実機が必要です。", "Screen audio capture requires a physical iOS 27 device.")).font(.caption).foregroundStyle(.secondary)
            #endif
            if model.screenCaptureFinishing { ProgressView(t("正在保存屏幕声音", "画面の音声を保存中", "Saving screen audio")) }
            if !model.importStatus.isEmpty { ProgressView(model.importStatus) }
        }
    }

    private func meetingCard(_ meeting: Meeting) -> some View {
        card {
            TextField(t("会议标题", "会議タイトル", "Meeting title"), text: $title)
                .font(.headline)
                .onSubmit { model.rename(meeting.id, title: title) }
            HStack {
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text("\(meeting.durationMs / 1000)s")
            }.font(.caption).foregroundStyle(.secondary)
            Button(t("保存标题", "タイトルを保存", "Save title")) { model.rename(meeting.id, title: title) }
                .font(.caption)
            if let recovery = model.screenRecoveryURL(for: meeting.id) {
                Text(t("屏幕录制待恢复", "画面録画の復旧が必要です", "Screen capture needs recovery"))
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    Button(t("重试提取声音", "音声抽出を再試行", "Retry audio extraction")) {
                        Task { await model.retryScreenRecovery(for: meeting.id) }
                    }.disabled(model.busy)
                    ShareLink(item: recovery) { Text(t("导出原始录制", "元の録画を書き出す", "Export original capture")) }
                }.font(.caption)
            }
        }
    }

    @ViewBuilder private func content(_ meeting: Meeting) -> some View {
        switch panel {
        case .transcript:
            card {
                HStack {
                    Text(panelName(.transcript)).font(.headline)
                    Spacer()
                    Button(t("重新转写", "再文字起こし", "Retranscribe")) { Task { await model.transcribeSaved(for: meeting.id) } }
                        .disabled(model.busy || meeting.state != "stopped")
                }
                if meeting.segments.isEmpty { Text(t("暂无转写。录音会先保存在本机。", "文字起こしはまだありません。録音は端末に保存されています。", "No transcript yet. The recording is saved locally.")) }
                if model.isRecording && !model.partialText.isEmpty {
                    Text(model.partialText).italic().foregroundStyle(.secondary)
                        .accessibilityLabel(t("临时识别：", "暫定認識：", "Interim transcript: ") + model.partialText)
                }
                ForEach(meeting.segments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        Button(String(format: "%02d:%02d", segment.startMs / 60_000, segment.startMs / 1000 % 60)) {
                            seekRequest = SeekRequest(milliseconds: segment.startMs)
                        }.font(.caption.monospacedDigit())
                        Button(segment.speaker) { renameSource = segment.speaker; renameSegment = segment.id; renameDraft = segment.speaker }
                            .font(.caption.weight(.semibold))
                        Text(segment.text).textSelection(.enabled)
                        if !segment.translation.isEmpty { Text(segment.translation).foregroundStyle(.indigo).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    // The editor opens right under the tapped sentence, not after the whole list,
                    // so it is visible without scrolling in a long meeting.
                    if renameSegment == segment.id, let renameSource { speakerEditor(meeting, source: renameSource) }
                    Divider()
                }
                Button(t("智能区分说话人", "AI で話者を区分", "AI speaker split")) {
                    Task { await model.resplitSpeakers(for: meeting.id) }
                }.disabled(model.busy || meeting.segments.isEmpty)
                Button(t("翻译全部", "すべて翻訳", "Translate all")) { Task { await model.translateAll(for: meeting.id) } }
                    .disabled(model.busy || meeting.segments.isEmpty)
            }
        case .summary:
            textPanel(meeting.summary, empty: t("暂无摘要", "要約はまだありません", "No summary yet"), action: t("生成摘要", "要約を作成", "Create summary")) {
                Task { await model.summarize(for: meeting.id) }
            }
        case .minutes:
            noteOptions(meeting)
            let isClass = meeting.noteMode == NotesPrompts.classroom
            textPanel(meeting.minutes, empty: isClass ? t("暂无课程笔记", "授業ノートはまだありません", "No class notes yet") : t("暂无纪要", "議事録はまだありません", "No minutes yet"),
                      action: isClass ? t("生成笔记", "ノートを作成", "Create notes") : t("生成纪要", "議事録を作成", "Create minutes")) {
                Task { await model.createMinutes(for: meeting.id) }
            }
        case .ask:
            card {
                Text(panelName(.ask)).font(.headline)
                ForEach(meeting.questions) { entry in
                    Text(entry.question).fontWeight(.semibold).textSelection(.enabled)
                    Text(entry.answer).textSelection(.enabled)
                    Divider()
                }
                TextField(t("问这场会议…", "この会議について質問…", "Ask about this meeting…"), text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button(t("提问", "質問", "Ask")) {
                    let value = question; question = ""
                    Task { await model.ask(value, for: meeting.id) }
                }.disabled(model.busy || question.isEmpty)
            }
        case .stats:
            card {
                Text(panelName(.stats)).font(.headline)
                LabeledContent(t("识别调用", "認識回数", "ASR calls"), value: "\(meeting.asrCalls)")
                LabeledContent(t("已完成的文本操作", "完了したテキスト操作", "Completed text actions"), value: "\(meeting.llmCalls)")
                if let seconds = meeting.asrProcessedSeconds {
                    LabeledContent(t("已处理音频", "処理済み音声", "Processed audio"), value: String(format: "%.1fs", seconds))
                }
                ForEach((meeting.asrEstimatedCostByCurrency ?? [:]).keys.sorted(), id: \.self) { currency in
                    if let cost = meeting.asrEstimatedCostByCurrency?[currency] {
                        LabeledContent(t("识别估算费用", "認識の推定費用", "Estimated ASR cost"),
                                       value: String(format: "%.4f %@", cost, currency))
                    }
                }
                ForEach((meeting.textUsageByTask ?? [:]).keys.sorted(), id: \.self) { task in
                    if let usage = meeting.textUsageByTask?[task] {
                        LabeledContent(task, value: "\(usage.calls) · \(usage.promptTokens) / \(usage.completionTokens) tokens")
                        if let reasoning = usage.reasoningTokens {
                            Text(t("其中思考 token", "うち思考トークン", "Of which reasoning tokens") + ": \(reasoning)").font(.caption).foregroundStyle(.secondary)
                        }
                        if usage.unreportedCalls > 0 {
                            Text("\(task): \(usage.unreportedCalls) " + t("次未返回用量", "件の使用量が未報告", "calls without token usage"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(t("费用按设置价格估算；服务商账单为准。旧会议及失败请求可能缺少用量。", "費用は設定した価格による推定です。請求はサービス提供者の記録を確認してください。旧会議や失敗したリクエストは使用量が欠ける場合があります。", "Cost uses configured rates; provider billing is authoritative. Older meetings and failed requests may lack usage."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(t("转写片段", "文字起こし数", "Segments"), value: "\(meeting.segments.count)")
                LabeledContent(t("录音时长", "録音時間", "Audio seconds"), value: "\(meeting.durationMs / 1000)")
            }
        }
    }

    private func copyControl(_ meeting: Meeting) -> some View {
        let value: String = {
            switch panel {
            case .transcript: return meeting.segments.map { segment in
                [segment.speaker, segment.text, segment.translation].filter { !$0.isEmpty }.joined(separator: "\n")
            }.joined(separator: "\n\n")
            case .summary: return meeting.summary
            case .minutes: return meeting.minutes
            case .ask: return meeting.questions.map { $0.question + "\n" + $0.answer }.joined(separator: "\n\n")
            case .stats: return ""
            }
        }()
        return HStack {
            if model.busy { ProgressView(); Text(t("模型正在处理", "モデルで処理中", "Processing with model")).font(.caption) }
            Spacer()
            Button {
                UIPasteboard.general.string = value
                copied = true
            } label: {
                Label(copied ? t("已复制", "コピーしました", "Copied") : t("复制全文", "全文をコピー", "Copy all"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }.buttonStyle(.bordered).disabled(value.isEmpty)
        }
        .onChange(of: panel) { _, _ in copied = false }
        .onChange(of: value) { _, _ in copied = false }
    }

    private func textPanel(_ value: String, empty: String, action: String, perform: @escaping () -> Void) -> some View {
        card {
            Group {
                if value.isEmpty { Text(empty) } else { MarkdownView(markdown: value) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action, action: perform).disabled(model.busy || model.selected?.segments.isEmpty != false)
        }
    }

    /// Speaker change for one sentence or everywhere (desktop speaker menu).
    @ViewBuilder private func speakerEditor(_ meeting: Meeting, source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(t("说话人名称", "話者名", "Speaker name"), text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            let known = Array(Set(meeting.segments.map(\.speaker))).filter { $0 != source && !$0.isEmpty }.sorted()
            if !known.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(known, id: \.self) { name in Button(name) { renameDraft = name }.buttonStyle(.bordered) } }
                }
            }
            Text(t("改成已有名字时，「全部改名」会合并这两位说话人。", "既存の名前にすると「すべて変更」で話者が統合されます。", "Renaming everywhere to an existing name merges the two speakers."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let segmentID = renameSegment {
                    Button(t("只改这一句", "この文だけ", "This sentence")) {
                        model.setSegmentSpeaker(segmentID, to: renameDraft, for: meeting.id)
                        self.renameSource = nil
                    }
                }
                Button(t("全部改名", "すべて変更", "Everywhere")) {
                    model.renameSpeaker(source, to: renameDraft, for: meeting.id)
                    self.renameSource = nil
                }
                Button(t("取消", "キャンセル", "Cancel")) { self.renameSource = nil }
            }
        }
    }

    /// Scene (meeting/class) and notes detail of this meeting, as on the desktop notes panel.
    private func noteOptions(_ meeting: Meeting) -> some View {
        card {
            Picker(t("使用场景", "利用シーン", "Scene"), selection: Binding(
                get: { meeting.noteMode }, set: { model.setNoteOptions(mode: $0, detail: meeting.noteDetail, for: meeting.id) })) {
                Text(t("会议", "会議", "Meeting")).tag(NotesPrompts.meeting)
                Text(t("上课", "授業", "Class")).tag(NotesPrompts.classroom)
            }.pickerStyle(.segmented)
            Picker(t("纪要详细度", "詳しさ", "Notes detail"), selection: Binding(
                get: { meeting.noteDetail }, set: { model.setNoteOptions(mode: meeting.noteMode, detail: $0, for: meeting.id) })) {
                Text(t("详细", "詳細", "Detailed")).tag(NotesPrompts.detailed)
                Text(t("标准", "標準", "Standard")).tag(NotesPrompts.standard)
            }.pickerStyle(.segmented)
            Text(t("切换后已有内容保留，请重新生成。", "切り替えても既存の内容は残ります。再生成してください。", "Existing notes are kept; regenerate to apply."))
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy)
    }

    private func exportCard(_ meeting: Meeting) -> some View {
        card {
            Text(t("导出", "書き出し", "Export")).font(.headline)
            ScrollView(.horizontal) {
                HStack {
                ForEach(["md", "md-notes", "txt", "vtt", "bilingual-vtt", "srt", "json"], id: \.self) { format in
                    Button(format == "md-notes" ? t("MD 不含转写", "MD（文字起こしなし）", "MD without transcript") : format.uppercased()) {
                        if let url = model.export(meeting.id, format: format) { sharedFile = SharedFile(url: url) }
                    }
                    .buttonStyle(.bordered)
                }
                }
            }
        }
    }

    private func panelName(_ panel: Panel) -> String {
        switch panel {
        case .transcript: return t("转写", "文字起こし", "Transcript")
        case .summary: return t("摘要", "要約", "Summary")
        case .minutes: return t("纪要", "議事録", "Minutes")
        case .ask: return t("问答", "質問", "Ask")
        case .stats: return t("统计", "統計", "Stats")
        }
    }

    private func t(_ zh: String, _ ja: String, _ en: String) -> String { L10n.text(model.settings.uiLanguage, zh, ja, en) }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct AudioPlayback: View {
    let url: URL?
    let language: String
    let seekRequest: SeekRequest?
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var position: Double = 0
    @State private var duration: Double = 0

    var body: some View {
        if let url {
            card {
                Slider(value: Binding(
                    get: { position },
                    set: { position = $0; player?.currentTime = $0 }
                ), in: 0...max(duration, 0.1))
                HStack {
                    Text(time(position))
                    Spacer()
                    Text(time(duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(playing ? t("暂停播放", "再生を一時停止", "Pause audio") : t("播放录音", "録音を再生", "Play audio")) {
                    if playing { player?.pause(); playing = false }
                    else {
                        if player == nil { prepare(url) }
                        playing = player?.play() ?? false
                    }
                }
                ShareLink(item: url) { Label(t("分享 WAV", "WAV を共有", "Share WAV"), systemImage: "square.and.arrow.up") }
            }
            .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
                position = player?.currentTime ?? position
                if playing && player?.isPlaying != true { playing = false }
            }
            .onAppear { prepare(url) }
            .onChange(of: url) { _, next in prepare(next) }
            .onChange(of: seekRequest?.id) { _, _ in
                guard let seekRequest else { return }
                if player == nil { prepare(url) }
                player?.currentTime = Double(seekRequest.milliseconds) / 1000
                position = player?.currentTime ?? 0
                playing = player?.play() ?? false
            }
            .onDisappear { player?.stop(); player = nil; playing = false }
        }
    }

    private func t(_ zh: String, _ ja: String, _ en: String) -> String { L10n.text(language, zh, ja, en) }

    private func prepare(_ url: URL?) {
        player?.stop()
        player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        position = 0
        playing = false
    }

    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    let open: () -> Void
    @State private var pendingDelete: UUID?

    var body: some View {
        List {
            ForEach(model.meetings) { meeting in
                Button {
                    model.selectedID = meeting.id
                    open()
                } label: {
                    VStack(alignment: .leading) {
                        Text(meeting.title).font(.headline).foregroundStyle(.primary)
                        Text("\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(meeting.durationMs / 1000)s · \(meeting.segments.count) \(L10n.text(model.settings.uiLanguage, "片段", "区間", "segments"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .swipeActions { Button(role: .destructive) { pendingDelete = meeting.id } label: { Label(L10n.text(model.settings.uiLanguage, "删除", "削除", "Delete"), systemImage: "trash") } }
            }
        }
        .navigationTitle(L10n.text(model.settings.uiLanguage, "历史会议", "会議履歴", "History"))
        .confirmationDialog(L10n.text(model.settings.uiLanguage, "删除此会议及其本地 WAV？", "この会議と端末内の WAV を削除しますか？", "Delete this meeting and its local WAV?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.text(model.settings.uiLanguage, "删除", "削除", "Delete"), role: .destructive) { if let id = pendingDelete { model.delete(id) }; pendingDelete = nil }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = AppSettings()
    @State private var asrKey = ""
    @State private var llmKey = ""
    @State private var providerDraft = ProviderCatalog()
    @State private var realtimeDraft = RealtimeSettings()
    @State private var summaryMinCharacters = 200
    @State private var providerKeys: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        Form {
            Section(t("界面", "表示", "Interface")) {
                Picker(t("语言", "言語", "Language"), selection: $draft.uiLanguage) {
                    Text("中文").tag("zh"); Text("日本語").tag("ja"); Text("English").tag("en")
                }
            }
            Section(t("任务模型路由", "タスク別モデル", "Models by task")) {
                Text(t("获取列表会联系所选服务；可随时手动输入模型 ID。思考设置仅用于 DeepSeek 官方接口。", "一覧の取得は選択したサービスに接続します。モデル ID は手動入力も可能です。思考設定は DeepSeek 公式 API のみです。", "Fetching models contacts the selected service. You can also enter a model ID manually. Thinking controls apply to the official DeepSeek API.")).font(.caption).foregroundStyle(.secondary)
                ForEach(["summary", "minutes", "translation", "ask", "speaker"], id: \.self) { task in
                    TaskModelEditor(task: task, role: Binding(
                        get: { providerDraft.roles[task] ?? ModelRole(provider: "", model: "") },
                        set: { providerDraft.roles[task] = $0 }
                    ), providers: providerDraft.text, keys: providerKeys, settings: draft)
                }
            }
            Section(t("录音与实时识别", "録音とリアルタイム認識", "Recording and live transcription")) {
                Toggle(t("实时发送音频片段到 ASR", "音声を ASR にリアルタイム送信", "Send live chunks to ASR"), isOn: $draft.liveTranscription)
                Text(t("即使模型失败，录音也会保存在本机。", "モデルが失敗しても録音は端末に保存されます。", "The recording remains on this device if a model fails."))
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("\(t("分段", "分割", "Chunk")): \(draft.chunkSeconds)s", value: $draft.chunkSeconds, in: 10...120)
                Stepper("\(t("重叠", "重複", "Overlap")): \(draft.overlapSeconds)s", value: $draft.overlapSeconds, in: 0...10)
                Stepper("\(t("自动摘要", "自動要約", "Auto summary")): \(draft.autoSummarySeconds)s", value: $draft.autoSummarySeconds, in: 0...1800, step: 60)
                Stepper("\(t("最少新增文字", "新規テキストの最小量", "Minimum new characters")): \(summaryMinCharacters)",
                        value: $summaryMinCharacters, in: 0...2_000, step: 50)
            }
            Section(t("句级实时识别", "発話単位のリアルタイム認識", "Utterance recognition")) {
                Stepper("\(t("临时识别间隔", "暫定認識間隔", "Interim interval")): \(realtimeDraft.stepSeconds)s",
                        value: $realtimeDraft.stepSeconds, in: 2...10)
                Stepper("\(t("最少新增音频", "新規音声の最小量", "Minimum new audio")): \(realtimeDraft.minNewSeconds, specifier: "%.1f")s",
                        value: $realtimeDraft.minNewSeconds, in: 0.5...5, step: 0.5)
                Stepper("\(t("静音定稿", "無音で確定", "Finalize after silence")): \(realtimeDraft.silenceMilliseconds)ms",
                        value: $realtimeDraft.silenceMilliseconds, in: 400...4_000, step: 100)
                Stepper("\(t("最长单句", "発話の最長", "Max utterance")): \(realtimeDraft.maxUtteranceSeconds)s",
                        value: $realtimeDraft.maxUtteranceSeconds, in: 10...120, step: 5)
                Stepper("\(t("切分重叠", "分割の重複", "Split overlap")): \(realtimeDraft.overlapMilliseconds)ms",
                        value: $realtimeDraft.overlapMilliseconds, in: 0...3_000, step: 100)
                Text("\(t("语音门限", "音声しきい値", "Voice threshold")): \(realtimeDraft.vadThreshold, specifier: "%.4f")")
                Slider(value: $realtimeDraft.vadThreshold, in: 0.0001...0.02)
            }
            Section("ASR") {
                Text(t("旧版单服务配置；下面的多服务设置启用后优先使用。", "旧版の単一サービス設定。下の複数サービス設定が優先されます。", "Legacy single-service settings. Enabled providers below take priority."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Base URL (https://.../v1)", text: $draft.asrBaseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Model ID", text: $draft.asrModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key", text: $asrKey)
                Toggle(t("无需 API Key", "API Key 不要", "No API key"), isOn: $draft.asrNoAuth)
                Picker(t("识别语言", "認識言語", "Speech language"), selection: $draft.asrLanguage) {
                    Text("Auto").tag("auto"); Text("中文").tag("zh"); Text("日本語").tag("ja"); Text("English").tag("en")
                    Text("한국어").tag("ko"); Text("Français").tag("fr"); Text("Deutsch").tag("de"); Text("Español").tag("es")
                }
            }
            Section(t("多个语音服务", "複数の音声認識サービス", "ASR providers")) {
                Picker(t("优先引擎", "優先エンジン", "Preferred engine"), selection: $providerDraft.activeASR) {
                    Text("Auto").tag("auto")
                    ForEach(providerDraft.asr) { provider in Text(provider.id).tag(provider.id) }
                }
                ForEach($providerDraft.asr) { $provider in
                    DisclosureGroup(provider.id) {
                        Toggle(t("启用", "有効", "Enabled"), isOn: $provider.enabled)
                        Picker(t("协议", "方式", "Protocol"), selection: $provider.kind) {
                            Text("OpenAI audio").tag("openai-audio")
                            Text("MiMo").tag("mimo")
                            Text("Deepgram").tag("deepgram")
                        }
                        TextField("Base URL", text: $provider.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Model ID", text: $provider.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField(t("语言：逗号分隔", "言語：カンマ区切り", "Languages, comma-separated"), text: Binding(
                            get: { provider.languages.joined(separator: ",") },
                            set: { provider.languages = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                        ))
                        SecureField("API Key", text: keyBinding("asr.\(provider.id)"))
                        Toggle(t("无需 API Key", "API Key 不要", "No API key"), isOn: $provider.noAuth)
                        TextField(t("估算单价/小时", "推定価格/時間", "Estimated price/hour"), value: $provider.pricePerHour, format: .number)
                            .keyboardType(.decimalPad)
                        TextField(t("币种", "通貨", "Currency"), text: Binding(
                            get: { provider.currency ?? "USD" }, set: { provider.currency = $0.uppercased() }
                        )).textInputAutocapitalization(.characters)
                    }
                }
                Button(t("添加自定义 ASR", "カスタム ASR を追加", "Add custom ASR")) {
                    let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
                    providerDraft.asr.append(ASRProvider(id: id, kind: "openai-audio", enabled: false,
                        baseURL: "", model: "", languages: ["auto"]))
                }
            }
            Section(t("语音语言路由", "音声言語のルーティング", "Speech language routing")) {
                ForEach(["auto", "zh", "en", "ja", "ko", "fr", "de", "es"], id: \.self) { language in
                    Picker(language, selection: Binding(
                        get: { providerDraft.routes[language] ?? "auto" },
                        set: { providerDraft.routes[language] = $0 }
                    )) {
                        Text("Auto").tag("auto")
                        ForEach(providerDraft.asr) { provider in Text(provider.id).tag(provider.id) }
                    }
                }
            }
            Section("Text model") {
                Text(t("旧版单服务配置；下面的任务路由启用后优先使用。", "旧版の単一サービス設定。下のタスク設定が優先されます。", "Legacy single-service settings. Task routes below take priority."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Base URL (https://.../v1)", text: $draft.llmBaseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Default model ID", text: $draft.llmModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("API Key", text: $llmKey)
                Toggle(t("无需 API Key", "API Key 不要", "No API key"), isOn: $draft.llmNoAuth)
                TextField("Summary model (optional)", text: $draft.summaryModel)
                TextField("Minutes model (optional)", text: $draft.minutesModel)
                TextField("Translation model (optional)", text: $draft.translationModel)
                TextField("Ask model (optional)", text: $draft.askModel)
                Picker(t("使用场景", "利用シーン", "Scene"), selection: Binding(
                    get: { NotesPrompts.normalizeMode(draft.noteMode) }, set: { draft.noteMode = $0 })) {
                    Text(t("会议：决议、待办、风险", "会議：決定・タスク・リスク", "Meeting: decisions, actions, risks")).tag(NotesPrompts.meeting)
                    Text(t("上课：概念、例题、复习问答", "授業：概念・例題・復習", "Class: concepts, examples, review")).tag(NotesPrompts.classroom)
                }
                Picker(t("纪要详细度", "議事録の詳しさ", "Notes detail"), selection: Binding(
                    get: { NotesPrompts.normalizeDetail(draft.notesDetail) }, set: { draft.notesDetail = $0 })) {
                    Text(t("详细", "詳細", "Detailed")).tag(NotesPrompts.detailed)
                    Text(t("标准", "標準", "Standard")).tag(NotesPrompts.standard)
                }
                Picker(t("翻译目标", "翻訳先", "Translate to"), selection: $draft.translateTo) {
                    Text("Off").tag(""); Text("中文").tag("zh"); Text("日本語").tag("ja"); Text("English").tag("en")
                    Text("한국어").tag("ko"); Text("Français").tag("fr"); Text("Deutsch").tag("de"); Text("Español").tag("es")
                }
            }
            Section(t("多个文本模型服务", "複数のテキストモデル", "Text model providers")) {
                ForEach($providerDraft.text) { $provider in
                    DisclosureGroup(provider.id) {
                        Toggle(t("启用", "有効", "Enabled"), isOn: $provider.enabled)
                        TextField("Base URL", text: $provider.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("API Key", text: keyBinding("llm.\(provider.id)"))
                        Toggle(t("无需 API Key", "API Key 不要", "No API key"), isOn: $provider.noAuth)
                    }
                }
                Button(t("添加自定义文本服务", "カスタムテキストサービスを追加", "Add text provider")) {
                    let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
                    providerDraft.text.append(TextProvider(id: id, enabled: false, baseURL: ""))
                }
            }
            Section(t("网络", "ネットワーク", "Network")) {
                Toggle(t("允许不安全 HTTP", "安全でない HTTP を許可", "Allow insecure HTTP"), isOn: $draft.allowInsecureHTTP)
                Text(t("HTTP 不加密音频、文字或密钥；仅用于可信的本地服务。", "HTTP では音声・テキスト・キーが暗号化されません。信頼できるローカルサービスに限ってください。", "HTTP does not encrypt audio, text or keys. Use only with a trusted local service."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(t("保存设置", "設定を保存", "Save settings"), action: save)
        }
        .navigationTitle(t("设置", "設定", "Settings"))
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(t("保存", "保存", "Save"), action: save) } }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = model.settings
            asrKey = model.asrKey
            llmKey = model.llmKey
            providerDraft = model.settings.providers ?? ProviderCatalog()
            realtimeDraft = model.settings.realtime ?? RealtimeSettings()
            summaryMinCharacters = model.settings.autoSummaryMinCharacters ?? 200
            providerKeys = [:]
            for provider in providerDraft.asr { providerKeys["asr.\(provider.id)"] = SecretStore.read("asr.\(provider.id)") }
            for provider in providerDraft.text { providerKeys["llm.\(provider.id)"] = SecretStore.read("llm.\(provider.id)") }
        }
    }

    private func save() {
        var value = draft
        value.providers = providerDraft
        value.realtime = realtimeDraft
        value.autoSummaryMinCharacters = summaryMinCharacters
        model.saveSettings(value, asrKey: asrKey, llmKey: llmKey, providerKeys: providerKeys)
    }

    private func keyBinding(_ account: String) -> Binding<String> {
        Binding(get: { providerKeys[account] ?? "" }, set: { providerKeys[account] = $0 })
    }

    private func t(_ zh: String, _ ja: String, _ en: String) -> String { L10n.text(draft.uiLanguage, zh, ja, en) }
}

private struct TaskModelEditor: View {
    let task: String
    @Binding var role: ModelRole
    let providers: [TextProvider]
    let keys: [String: String]
    let settings: AppSettings
    @State private var models: [String] = []
    @State private var loading = false
    @State private var status = ""
    @State private var requestID = UUID()

    private var provider: TextProvider? { providers.first { $0.id == role.provider } }
    private var name: String {
        switch task {
        case "summary": return t("摘要", "要約", "Summary")
        case "minutes": return t("纪要", "議事録", "Minutes")
        case "translation": return t("翻译", "翻訳", "Translation")
        case "ask": return t("问答", "質問応答", "Q&A")
        default: return t("说话人区分", "話者区分", "Speaker split")
        }
    }

    var body: some View {
        DisclosureGroup {
            Picker(t("服务", "サービス", "Provider"), selection: Binding(
                get: { role.provider },
                set: { id in
                    guard id != role.provider, let selected = providers.first(where: { $0.id == id }) else { return }
                    role = ModelRole.initial(provider: selected, task: task)
                    resetList()
                }
            )) {
                Text(t("选择服务", "サービスを選択", "Select provider")).tag("")
                ForEach(providers) { Text($0.id).tag($0.id) }
            }
            .accessibilityIdentifier("provider-" + task)
            if !models.isEmpty {
                Picker(t("选择模型", "モデルを選択", "Select model"), selection: $role.model) {
                    Text(t("手动输入", "手動入力", "Enter manually")).tag("")
                    if !role.model.isEmpty && !models.contains(role.model) { Text(role.model).tag(role.model) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Model ID", text: $role.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("model-" + task)
            HStack {
                Button(t("获取模型列表", "モデル一覧を取得", "Fetch models"), action: fetch)
                    .disabled(loading || provider == nil)
                if loading { ProgressView() }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let provider, ModelRole.isDeepSeek(provider.baseURL) {
                Picker(t("思考模式", "思考モード", "Thinking mode"), selection: Binding(
                    get: { role.thinking ?? "default" }, set: { role.thinking = $0 }
                )) {
                    Text(t("服务默认", "サービス既定", "Provider default")).tag("default")
                    Text(t("关闭", "無効", "Disabled")).tag("disabled")
                    Text(t("开启", "有効", "Enabled")).tag("enabled")
                }
            }
            if provider?.enabled == false {
                Text(t("请在下面启用此文本服务。", "下の設定でこのサービスを有効にしてください。", "Enable this text provider below.")).font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(role.model.isEmpty ? t("尚未选择模型", "モデル未選択", "Choose a model") : role.provider + " · " + role.model)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .onChange(of: provider) { _, _ in resetList() }
        .onChange(of: keys["llm." + role.provider]) { _, _ in resetList() }
        .onDisappear { resetList() }
    }

    private func resetList() { requestID = UUID(); loading = false; models = []; status = "" }
    private func fetch() {
        guard let selected = provider else { return }
        let id = UUID()
        requestID = id
        loading = true
        status = ""
        let key = keys["llm." + selected.id] ?? ""
        Task { @MainActor in
            do {
                let result = try await CloudClient(settings: settings).discoverModels(baseURL: selected.baseURL, key: key, noAuth: selected.noAuth)
                guard requestID == id, provider == selected else { return }
                // Discovery populates choices, never changes the user's typed model ID.
                models = result
                status = "\(result.count) " + t("个模型", "件のモデル", "models")
            } catch {
                guard requestID == id else { return }
                status = error.localizedDescription
            }
            loading = false
        }
    }
    private func t(_ zh: String, _ ja: String, _ en: String) -> String { L10n.text(settings.uiLanguage, zh, ja, en) }
}

@ViewBuilder private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
}

/// Summaries and notes as headings, lists and tables instead of raw `#` and `|` (see MarkdownBlock).
private struct MarkdownView: View {
    let markdown: String

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, level <= 2 ? 6 : 2)
                case .bullet(let text, let depth, let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.indigo)
                        inline(text)
                    }.padding(.leading, CGFloat(depth) * 14)
                case .table(let header, let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, cell in inline(cell).font(.caption.bold()) } }
                            Divider()
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                GridRow {
                                    ForEach(0..<max(header.count, row.count), id: \.self) { index in
                                        inline(index < row.count ? row[index] : "").font(.caption)
                                    }
                                }
                            }
                        }
                    }
                case .quote(let text):
                    inline(text).foregroundStyle(.secondary).padding(.leading, 10)
                case .code(let text):
                    Text(text).font(.caption.monospaced()).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                case .paragraph(let text):
                    inline(text)
                case .rule:
                    Divider()
                }
            }
        }
    }
}

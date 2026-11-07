import Foundation
import XCTest
@testable import BabelEchoCoreChecks

/// Behaviour ported from the desktop app; mirrors apps/android DesktopParityTest and SentencesTest.
final class ParityChecks: XCTestCase {
    private func segment(_ text: String, _ start: Int, _ end: Int, speaker: String = "老师") -> TranscriptSegment {
        TranscriptSegment(startMs: start, endMs: end, text: text, speaker: speaker)
    }

    func testSentenceSplittingJoiningAndGrouping() {
        XCTAssertEqual(Sentences.split("今天开会。讨论预算！还有"), ["今天开会。", "讨论预算！", "还有"])
        XCTAssertEqual(Sentences.split("「はい。」そうです"), ["「はい。」", "そうです"])
        XCTAssertEqual(Sentences.split("Version 3.5 shipped. Next we"), ["Version 3.5 shipped.", "Next we"])
        XCTAssertTrue(Sentences.endsSentence("终于结束了。"))
        XCTAssertTrue(Sentences.endsSentence("他说「好的。」"))
        XCTAssertFalse(Sentences.endsSentence("然后我们"))
        XCTAssertFalse(Sentences.endsSentence("pi is 3.14"))
        XCTAssertEqual(Sentences.join("我们下周", "再讨论"), "我们下周再讨论")
        XCTAssertEqual(Sentences.join("we will", "meet"), "we will meet")
        XCTAssertEqual(Sentences.group(["短。", "也短。", "这一句比较长一些。"], target: 6), ["短。也短。", "这一句比较长一些。"])
    }

    func testOverlapTrimmingMatchesDesktop() {
        XCTAssertEqual(Sentences.trimRepeatedPrefix(previous: "我们讨论预算问题", current: "预算问题，然后继续"), "然后继续")
        XCTAssertEqual(Sentences.trimRepeatedPrefix(previous: "the budget review", current: "Budget review. next part"), "next part")
        XCTAssertEqual(Sentences.trimRepeatedPrefix(previous: "完全不同", current: "全新的话"), "全新的话")
        XCTAssertEqual(Sentences.trimRepeatedPrefix(previous: "xab", current: "ab"), "ab")
    }

    func testCutSentencesAreReassembledAndOnlyCompleteOnesAreReleased() {
        var assembler = TranscriptAssembler()
        var segments: [TranscriptSegment] = []
        var change = assembler.add("我们先看预算。然后下个季度的", startMs: 0, endMs: 20_000, speaker: "说话人1")
        segments = change.apply(to: segments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(change.closedIDs, [segments[0].id])
        XCTAssertEqual(assembler.openSegmentID, segments[1].id)

        change = assembler.add("计划要重新排。另外", startMs: 19_000, endMs: 39_000, speaker: "说话人1")
        segments = change.apply(to: segments)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].text, "然后下个季度的计划要重新排。")
        XCTAssertTrue((20_001..<39_000).contains(segments[1].endMs))
        XCTAssertEqual(change.closedIDs, [segments[1].id])

        change = assembler.add("我同意", startMs: 39_100, endMs: 41_000, speaker: "说话人2")
        segments = change.apply(to: segments)
        XCTAssertEqual(segments[2].text, "另外", "a different speaker never continues the sentence")
        XCTAssertTrue(change.closedIDs.contains(segments[2].id))
        change = assembler.add("好的", startMs: 45_000, endMs: 46_000, speaker: "说话人2")
        segments = change.apply(to: segments)
        XCTAssertTrue(change.closedIDs.contains(segments[3].id), "a long gap closes the sentence")
        XCTAssertEqual(assembler.closeOpen(), segments[4].id)
        XCTAssertNil(assembler.closeOpen())
    }

    func testLongBlocksAreGroupedAndStaleSentencesClose() {
        var assembler = TranscriptAssembler()
        let sentence = "这是一个用来测试分组的句子。"
        let block = assembler.add(String(repeating: sentence, count: 20), startMs: 0, endMs: 28_000, speaker: "说话人1").added
        XCTAssertGreaterThanOrEqual(block.count, 3)
        XCTAssertTrue(block.allSatisfy { $0.text.count <= 80 + sentence.count })
        XCTAssertEqual(block.last?.endMs, 28_000)
        for index in 1..<block.count { XCTAssertEqual(block[index - 1].endMs, block[index].startMs) }

        var open = TranscriptAssembler()
        _ = open.add("还没有说完", startMs: 0, endMs: 2_000, speaker: "说话人1")
        XCTAssertNil(open.closeIfStale(nowMs: 4_000, graceMs: 2_000))
        XCTAssertNotNil(open.closeIfStale(nowMs: 6_000, graceMs: 2_000))

        // Text edits keep translations written meanwhile.
        var existing = [TranscriptSegment(startMs: 0, endMs: 1_000, text: "旧句子", translation: "", speaker: "说话人1")]
        var continuing = TranscriptAssembler(existing: [])
        let first = continuing.add("旧句子", startMs: 0, endMs: 1_000, speaker: "说话人1")
        existing = first.apply(to: [])
        existing[0].translation = "Old"
        let merged = continuing.add("继续。", startMs: 1_200, endMs: 2_000, speaker: "说话人1").apply(to: existing)
        XCTAssertEqual(merged[0].text, "旧句子继续。")
        XCTAssertEqual(merged[0].translation, "Old")
    }

    func testClassModeAndDetailChangeTheNotesPrompt() {
        let meeting = NotesPrompts.minutes(transcript: "[00:00] 老师：函数", title: "函数", summary: "", targetLanguage: "zh", mode: "meeting", notesDetail: "standard")
        let lesson = NotesPrompts.minutes(transcript: "[00:00] 老师：函数", title: "函数", summary: "", targetLanguage: "zh", mode: "class", notesDetail: "detailed")
        XCTAssertTrue(meeting.system.contains("会议记录撰写者") && meeting.system.contains("标准模式"))
        XCTAssertFalse(meeting.user.contains("keyConcepts"))
        XCTAssertTrue(lesson.system.contains("课堂笔记整理者") && lesson.system.contains("详细模式"))
        XCTAssertTrue(lesson.user.contains("keyConcepts") && lesson.user.contains("reviewQuestions"))
        let summary = NotesPrompts.summary(previous: nil, newSegments: [segment("开始", 0, 900)], maxChars: 900, title: "周会", mode: "meeting")
        XCTAssertTrue(summary.user.contains("（暂无，这是第一版摘要）") && summary.system.contains("不要输出 Mermaid"))
        XCTAssertEqual(NotesPrompts.timestamp(3_661_000), "1:01:01")
        XCTAssertEqual(NotesPrompts.timestamp(125_000), "02:05")
    }

    func testStructuredNotesRenderLikeDesktop() throws {
        let raw = """
        ```json
        {"abstract":"概述。","topics":[{"title":"函数","detail":"对应关系","points":["步骤一"]}],
         "keyConcepts":[{"term":"定义域","explanation":"自变量取值"}],
         "decisions":[{"decision":"采用方案A","context":"成本低"}],
         "actionItems":[{"task":"写报告|草稿","owner":"待定","due":"未定"}],
         "risks":["进度"],"keywords":["函数","映射"],"openQuestions":["何时考试"],
         "chapters":[{"start":"00:00","title":"导入","summary":"背景"}]}
        ```
        """
        let data = try XCTUnwrap(MinutesRenderer.parse(raw))
        let markdown = MinutesRenderer.render(data, mode: "class")
        for part in ["## 课程笔记", "概述。", "### 函数", "- 步骤一", "### 核心概念与公式", "#### 定义域", "### 关键决议",
                     "- 采用方案A（成本低）", "| 写报告\\|草稿 | 待定 | 未定 |", "- 进度", "关键词：函数、映射", "### 待确认问题", "#### 00:00 导入"] {
            XCTAssertTrue(markdown.contains(part), part)
        }
        XCTAssertTrue(MinutesRenderer.render(data, mode: "meeting", language: "en").hasPrefix("## Minutes"))
        XCTAssertNil(MinutesRenderer.parse("no json"))
    }

    private func response(_ request: URLRequest, _ content: String) -> (Data, HTTPURLResponse) {
        let body: [String: Any] = ["choices": [["message": ["content": content], "finish_reason": "stop"]]]
        return (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func configured() -> AppSettings {
        var settings = AppSettings()
        var catalog = ProviderCatalog()
        catalog.text = [TextProvider(id: "test", enabled: true, baseURL: "https://custom.example/v1", noAuth: true)]
        for task in ["summary", "minutes", "translation", "ask", "speaker"] { catalog.roles[task] = ModelRole(provider: "test", model: "m", thinking: nil) }
        settings.providers = catalog
        return settings
    }

    func testMinutesUseMeetingModeAndTranslationCarriesContext() async throws {
        var bodies: [[String: Any]] = []
        var replies: [String] = []
        let client = CloudClient(settings: configured(), credentials: { _ in "" }, transport: { request in
            bodies.append(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any])
            return self.response(request, replies.removeFirst())
        })
        var lesson = Meeting(title: "微积分")
        lesson.mode = "class"
        lesson.notesDetail = "standard"
        lesson.segments = [segment("今天讲极限。", 0, 1_000)]
        replies = ["{\"abstract\":\"课程概述\",\"keyConcepts\":[{\"term\":\"极限\",\"explanation\":\"趋近\"}]}"]
        let notes = try await client.minutes(lesson)
        XCTAssertTrue(notes.text.contains("## 课程笔记") && notes.text.contains("#### 极限"))
        XCTAssertEqual(bodies.last?["max_tokens"] as? Int, 16_384)
        let system = ((bodies.last?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(system.contains("课堂笔记整理者") && system.contains("标准模式"))

        let segments = (1...25).map { segment("第\($0)句。", $0 * 1_000, $0 * 1_000 + 900) }
        func reply(_ slice: ArraySlice<TranscriptSegment>) -> String {
            let items = slice.map { ["id": $0.id.uuidString, "text": "T" + $0.text] }
            return String(decoding: try! JSONSerialization.data(withJSONObject: ["translations": items]), as: UTF8.self)
        }
        replies = [reply(segments[0..<20]), reply(segments[20..<25])]
        let map = try await client.translate(segments, to: "ja", context: ["前文A。", "前文B。", "前文C。"])
        XCTAssertEqual(map.count, 25)
        let firstUser = ((bodies[bodies.count - 2]["messages"] as? [[String: Any]])?[1]["content"] as? String) ?? ""
        XCTAssertTrue(firstUser.contains("前文B。") && firstUser.contains("前文C。") && !firstUser.contains("前文A。"))
        let secondUser = ((bodies.last?["messages"] as? [[String: Any]])?[1]["content"] as? String) ?? ""
        XCTAssertTrue(secondUser.hasPrefix("前文（仅供理解，不要翻译）：\n第19句。\n第20句。"))
    }

    func testExportsSRTAndNotesWithoutTranscript() {
        var meeting = Meeting(title: "微积分")
        meeting.mode = "class"
        meeting.summary = "## 要点"
        meeting.minutes = "## 课程笔记\n\n概述"
        meeting.segments = [segment("极限 --> 定义", 61_234, 62_000), segment("明白", 62_000, 63_500, speaker: "学生")]
        let srt = MeetingExport.text(meeting, format: "srt")
        XCTAssertTrue(srt.hasPrefix("1\n00:01:01,234 --> 00:01:02,000\n老师: 极限 → 定义\n\n2\n"))
        let notes = MeetingExport.text(meeting, format: "md-notes")
        XCTAssertTrue(notes.contains("## 课堂摘要") && notes.contains("## 课程笔记"))
        XCTAssertFalse(notes.contains("Transcript") || notes.contains("极限"))
        XCTAssertTrue(MeetingExport.text(meeting, format: "md").contains("极限"))
        XCTAssertEqual(MeetingExport.fileExtension("md-notes"), "md")
        XCTAssertEqual(MeetingExport.suffix("md-notes"), "-notes")
    }

    func testOldMeetingsDefaultToMeetingModeAndDetailedNotes() throws {
        let old = try JSONDecoder().decode(Meeting.self, from: Data(#"{"title":"old","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":0,"durationMs":0,"state":"stopped","audioFile":"recording.wav","language":"auto","translateTo":"","segments":[],"summary":"","summaryUpTo":0,"minutes":"","questions":[],"asrCalls":0,"llmCalls":0,"schemaVersion":1}"#.utf8))
        XCTAssertEqual(old.noteMode, "meeting")
        XCTAssertEqual(old.noteDetail, "detailed")
    }

    func testOverlappingCuesEndWhereTheNextOneStarts() {
        var meeting = Meeting(title: "t")
        meeting.segments = [segment("第一段", 0, 12_000), segment("第二段", 10_000, 20_000)]
        XCTAssertTrue(MeetingExport.text(meeting, format: "srt").contains("00:00:00,000 --> 00:00:10,000"))
        XCTAssertTrue(MeetingExport.text(meeting, format: "vtt").contains("00:00:10.000 --> 00:00:20.000"))
    }
}

final class MarkdownBlockChecks: XCTestCase {
    func testNotesMarkdownBecomesBlocksWithoutLosingText() {
        let markdown = """
        ## 智能纪要

        概述**重点**在这里。
        第二行。

        ### 待办事项
        | 事项 | 负责人 | 截止 |
        | --- | --- | --- |
        | 写报告\\|草稿 | 待定 | 未定 |

        - 第一点
          - 子要点
        1. 步骤一
        - [ ] 任务
        > 引用
        ---
        ```
        code
        ```
        """
        let blocks = MarkdownBlock.parse(markdown)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "智能纪要"),
            .paragraph("概述**重点**在这里。\n第二行。"),
            .heading(level: 3, text: "待办事项"),
            .table(header: ["事项", "负责人", "截止"], rows: [["写报告|草稿", "待定", "未定"]]),
            .bullet(text: "第一点", depth: 0, marker: "•"),
            .bullet(text: "子要点", depth: 1, marker: "•"),
            .bullet(text: "步骤一", depth: 0, marker: "1."),
            .bullet(text: "任务", depth: 0, marker: "•"),
            .quote("引用"),
            .rule,
            .code("code"),
        ])
        XCTAssertEqual(MarkdownBlock.parse("只是普通文字"), [.paragraph("只是普通文字")])
    }

    func testRenderedStructuredNotesParseIntoATable() {
        let markdown = MinutesRenderer.render(["abstract": "概述", "actionItems": [["task": "写", "owner": "王", "due": "周五"]]], mode: "meeting")
        let tables = MarkdownBlock.parse(markdown).compactMap { block -> [[String]]? in
            if case .table(_, let rows) = block { return rows } else { return nil }
        }
        XCTAssertEqual(tables, [[["写", "王", "周五"]]])
    }
}

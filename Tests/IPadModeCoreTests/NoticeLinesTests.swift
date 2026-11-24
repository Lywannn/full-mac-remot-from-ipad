import Testing
@testable import IPadModeCore

/// R51: notices that arrive close together are shown together.
struct NoticeLinesTests {
    /// Adds each line in turn and says, for each, whether it was added.
    private func adding(_ added: [String], to notice: inout NoticeLines) -> [Bool] {
        added.map { notice.add($0) }
    }

    @Test func newLinesGoLast() {
        var notice = NoticeLines()
        #expect(adding(["a", "b"], to: &notice) == [true, true])
        #expect(notice.lines == ["a", "b"])
        #expect(notice.text == "a\nb")
    }

    @Test func exactDuplicatesAreDropped() {
        var notice = NoticeLines()
        _ = adding(["a", "b"], to: &notice)
        // Not new: the panel keeps its text and its timer.
        #expect(adding(["a", "b"], to: &notice) == [false, false])
        #expect(notice.lines == ["a", "b"])
        #expect(adding(["a "], to: &notice) == [true])   // only exact duplicates
        #expect(notice.lines == ["a", "b", "a "])
    }

    @Test func keepsTheNewestFour() {
        var notice = NoticeLines()
        #expect(adding(["1", "2", "3", "4", "5", "6"], to: &notice) == Array(repeating: true, count: 6))
        #expect(NoticeLines.limit == 4)
        #expect(notice.lines == ["3", "4", "5", "6"])
        #expect(adding(["1"], to: &notice) == [true])   // dropped earlier, so new again
        #expect(notice.lines == ["4", "5", "6", "1"])
    }

    @Test func startsAfreshOnceClosed() {
        var notice = NoticeLines()
        _ = adding(["a"], to: &notice)
        notice.removeAll()
        #expect(notice.lines.isEmpty && notice.text.isEmpty)
        #expect(adding(["a"], to: &notice) == [true])
        #expect(notice.lines == ["a"])
    }
}

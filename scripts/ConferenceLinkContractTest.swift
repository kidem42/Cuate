import Foundation

// Contract test for ConferenceLinkDetector — which links in an event count
// as "the call" and which field wins. Compiled STANDALONE with the detector:
//   swiftc ConferenceLinkDetector.swift ConferenceLinkContractTest.swift -o test
// Run via scripts/test-attach-note.sh.

@main
struct ConferenceLinkContractTest {
    static var failures = 0

    static func expect(_ name: String, _ condition: Bool) {
        if condition {
            print("  ok   \(name)")
        } else {
            failures += 1
            print("  FAIL \(name)")
        }
    }

    static func main() {
        let zoomInvite = """
        Pavel is inviting you to a scheduled Zoom meeting.

        Join Zoom Meeting
        https://us02web.zoom.us/j/81234567890?pwd=abcDEF123

        Meeting ID: 812 3456 7890
        """
        let zoom = ConferenceLinkDetector.detect(in: zoomInvite)
        expect("zoom invite in notes", zoom?.service == .zoom)
        expect("zoom link kept whole (query included)",
               zoom?.url.absoluteString == "https://us02web.zoom.us/j/81234567890?pwd=abcDEF123")

        let meet = ConferenceLinkDetector.detect(in: "https://meet.google.com/abc-defg-hij")
        expect("meet link in the location", meet?.service == .googleMeet)

        let teams = ConferenceLinkDetector.detect(in: """
        Microsoft Teams meeting
        Join on your computer: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d
        """)
        expect("teams meetup-join in notes", teams?.service == .teams)

        let telemost = ConferenceLinkDetector.detect(in: "Созвон: https://telemost.yandex.ru/j/12345678901234")
        expect("telemost link after cyrillic text", telemost?.service == .telemost)

        let ktalk = ConferenceLinkDetector.detect(in: "https://company.ktalk.ru/room123")
        expect("kontur.talk vanity subdomain", ktalk?.service == .konturTalk)

        expect("bare host is not a room",
               ConferenceLinkDetector.classify(URL(string: "https://zoom.us")!) == nil)
        expect("unknown host is not a call",
               ConferenceLinkDetector.detect(in: "Agenda: https://wiki.example.com/page/1") == nil)
        expect("mailto is not a call",
               ConferenceLinkDetector.detect(in: "mailto:someone@zoom.us") == nil)
        expect("lookalike host does not match by substring",
               ConferenceLinkDetector.classify(URL(string: "https://notzoom.us/j/1")!) == nil)

        // Field precedence: URL field, then location, then notes.
        let precedence = ConferenceLinkDetector.detect(
            url: URL(string: "https://whereby.com/pavel"),
            texts: ["https://meet.google.com/abc-defg-hij", zoomInvite])
        expect("url field wins over location and notes", precedence?.service == .whereby)
        let locationFirst = ConferenceLinkDetector.detect(
            url: URL(string: "https://wiki.example.com/agenda"),
            texts: ["https://meet.google.com/abc-defg-hij", zoomInvite])
        expect("unknown url field falls through to the location", locationFirst?.service == .googleMeet)
        let notesOnly = ConferenceLinkDetector.detect(url: nil, texts: ["Room 4.12", zoomInvite])
        expect("plain location falls through to the notes", notesOnly?.service == .zoom)

        expect("every service has a display name",
               ConferenceLink.Service.allCases.allSatisfy {
                   !ConferenceLink(url: URL(string: "https://example.com/x")!, service: $0).serviceName.isEmpty
               })

        if failures == 0 {
            print("conference link: all green")
        } else {
            print("conference link: \(failures) failure(s)")
            exit(1)
        }
    }
}

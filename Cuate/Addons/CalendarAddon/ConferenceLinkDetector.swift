import Foundation

/// An online-meeting link recognized in an event's fields.
struct ConferenceLink: Equatable {
    enum Service: String, CaseIterable {
        case zoom, googleMeet, teams, webex, facetime, telemost, jitsi, whereby
        case saluteJazz, konturTalk, chime, gotoMeeting, bluejeans
    }

    let url: URL
    let service: Service

    /// Product name shown next to the join action (never localized).
    var serviceName: String {
        switch service {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        case .telemost: "Yandex Telemost"
        case .jitsi: "Jitsi"
        case .whereby: "Whereby"
        case .saluteJazz: "SaluteJazz"
        case .konturTalk: "Kontur.Talk"
        case .chime: "Amazon Chime"
        case .gotoMeeting: "GoTo Meeting"
        case .bluejeans: "BlueJeans"
        }
    }
}

/// Finds the meeting link of a calendar event. EventKit exposes no
/// "conference" field for reading (Calendar.app parses its own), so the
/// link is fished out of the fields an invite lands in: the URL field, the
/// location (Google writes the Meet link there) and the notes (Zoom, Teams
/// and Webex invites). Only hosts on the list count — a Confluence page in
/// the URL field is not a call. Pure Foundation; the `EKEvent` entry point
/// lives in `CalendarEventSnapshot`.
enum ConferenceLinkDetector {

    /// Host suffix → service. Matching is by suffix so regional and vanity
    /// subdomains (us02web.zoom.us, company.ktalk.ru) count too.
    static let hosts: [(suffix: String, service: ConferenceLink.Service)] = [
        ("zoom.us", .zoom), ("zoom.com", .zoom), ("zoomgov.com", .zoom),
        ("meet.google.com", .googleMeet),
        ("teams.microsoft.com", .teams), ("teams.live.com", .teams),
        ("webex.com", .webex),
        ("facetime.apple.com", .facetime),
        ("telemost.yandex.ru", .telemost), ("telemost.yandex.com", .telemost),
        ("meet.jit.si", .jitsi),
        ("whereby.com", .whereby),
        ("jazz.sber.ru", .saluteJazz), ("salutejazz.ru", .saluteJazz),
        ("ktalk.ru", .konturTalk),
        ("chime.aws", .chime),
        ("gotomeeting.com", .gotoMeeting), ("gotomeet.me", .gotoMeeting),
        ("bluejeans.com", .bluejeans)
    ]

    /// The first recognized link across the fields, in the order given:
    /// callers pass the URL field first, then the location, then the notes.
    static func detect(url: URL?, texts: [String?]) -> ConferenceLink? {
        if let url, let link = classify(url) { return link }
        for text in texts {
            guard let text, !text.isEmpty, let link = detect(in: text) else { continue }
            return link
        }
        return nil
    }

    /// The first recognized link inside free text (an invite body).
    static func detect(in text: String) -> ConferenceLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        var found: ConferenceLink?
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let url = match?.url, let link = classify(url) else { return }
            found = link
            stop.pointee = true
        }
        return found
    }

    /// A web URL on a known host with a path — the bare host is a home
    /// page, not a room.
    static func classify(_ url: URL) -> ConferenceLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), url.path.count > 1 else { return nil }
        for entry in hosts where host == entry.suffix || host.hasSuffix("." + entry.suffix) {
            return ConferenceLink(url: url, service: entry.service)
        }
        return nil
    }
}

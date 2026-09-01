import Foundation

/// Second pass over an agent reply: turns a path MENTION into a path that
/// provably EXISTS on the agent's host.
///
/// `AgentFilePaths.extract` is a guess and cannot be anything else. Every
/// character a filename may hold — space, dash, bracket, colon, another
/// alphabet — is also a character prose holds, so "…/work/Demo Project —
/// rev.0.docx готов" has no determinable end when all you have is the text.
/// The HOST knows where the name ends, and both gateway kinds can be asked
/// with tools Hermes already ships: the local one through FileManager, the
/// remote one through the dashboard's own directory listing (`GET
/// /api/files?path=…` in `hermes_cli/web_server.py` — stock, not one of our
/// gateway patches, so `hermes update` cannot take it away).
///
/// The walk: take the mention up to the end of its line, list the deepest
/// directory that is unambiguous, and keep the LONGEST entry the remaining
/// text starts with — descending while that entry is a directory followed
/// by "/". What comes back is not a better guess; it is a path that exists.
///
/// Only ambiguous mentions cost a request: a path with no spaces in it is
/// already captured whole by the regex, so an ordinary reply resolves to
/// zero listings.
///
/// Deliberately NOT actor-isolated: views read the memo synchronously while
/// they render, so the caches sit behind a lock instead of an actor hop.
enum AgentPathResolver {

    private static let lock = NSLock()

    /// Reply text → the paths to show for it. A reply's text never changes,
    /// so this is a permanent memo (bounded by the chat's lifetime).
    private static var resolvedByText: [String: [String]] = [:]
    /// Directory → its entries, stamped: the agent creates files WHILE the
    /// chat is open, so a listing goes stale quickly.
    private static var listings: [String: (entries: [(name: String, isDirectory: Bool)], at: Date)] = [:]
    private static let listingTTL: TimeInterval = 15
    /// Verified paths that turned out to be FILES. Lets a chip offer a
    /// download for a name that carries no extension (`…/work/Makefile`),
    /// which the extension heuristic alone would drop as prose.
    private static var verifiedFiles = Set<String>()
    private static var inFlight = Set<String>()
    /// Paths the agent's own TOOL CALLS named, newest first. Not scoped to
    /// one conversation on purpose: they all describe the same host, and a
    /// path only ever wins here by matching the text being resolved.
    private static var toolPaths: [String] = []
    private static let toolPathLimit = 128

    /// One reply may not spend more than this many directory listings.
    private static let listingBudget = 8

    /// Records the files a tool call named. Called as the step starts, so
    /// the paths are in hand before the reply that mentions them arrives.
    static func noteToolPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for path in paths where !path.isEmpty {
            toolPaths.removeAll { $0 == path }
            toolPaths.insert(path, at: 0)
            // The step is about to create or change this file, so whatever
            // its directory looked like a moment ago is now wrong: drop the
            // listing instead of serving a copy that predates the write.
            listings.removeValue(forKey: (path as NSString).deletingLastPathComponent)
        }
        if toolPaths.count > toolPathLimit { toolPaths = Array(toolPaths.prefix(toolPathLimit)) }
    }

    /// The resolved set for a reply, if the walk already ran. Views call it
    /// while rendering and fall back to `AgentFilePaths.extract`.
    static func cached(for text: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return resolvedByText[text]
    }

    /// Whether the host confirmed this path is a file.
    static func isVerifiedFile(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return verifiedFiles.contains(path)
    }

    /// Resolves every ambiguous mention in `text` and memoizes the result.
    /// Returns the paths to show — verified where the host answered, the
    /// regex guess everywhere else (a file the agent named but never wrote
    /// still deserves the chip it always had).
    @discardableResult
    static func resolve(text: String) async -> [String] {
        let guesses = AgentFilePaths.extract(from: text)
        lock.lock()
        if let done = resolvedByText[text] { lock.unlock(); return done }
        let alreadyRunning = !inFlight.insert(text).inserted
        lock.unlock()
        if alreadyRunning { return guesses }
        defer { lock.lock(); inFlight.remove(text); lock.unlock() }

        var result = guesses
        var budget = listingBudget
        for span in mentions(in: text) {
            // 1. The agent's own tool call already named this file, exactly.
            //    Costs nothing and cannot be wrong about where the name ends.
            if let exact = toolPathHit(for: span) {
                merge(exact, from: span, into: &result)
                await noteFileness(of: exact, budget: &budget)
                continue
            }
            // 2. No tool named it. Ask the host only when the guess looks
            //    cut — a guess that already ends in an extension is whole,
            //    and an ordinary reply must not cost a single request.
            guard budget > 0, needsHost(span: span, guesses: guesses) else { continue }
            guard let found = await verify(span: span, budget: &budget) else { continue }
            // A resolution SHORTER than the guess is only believable when it
            // lands on a directory — that is the prose-swallow correction
            // ("…/work смотри файл report.docx" → "…/work"). Landing on a
            // shorter FILE means the named one does not exist and the walk
            // settled for a neighbour that happens to start the same way
            // ("…/Demo" for "…/Demo Project — rev.0.png"); the guess, wrong
            // as it may be, at least still names what the agent said.
            let guess = guesses.filter { span.hasPrefix($0) }.max { $0.count < $1.count }
            if found.isFile, let guess, found.path.count < guess.count { continue }
            merge(found.path, from: span, into: &result)
            if found.isFile {
                lock.lock(); verifiedFiles.insert(found.path); lock.unlock()
            }
        }
        // 3. Mentions with no root at all ("положил в work/отчёт.docx"):
        //    resolved against the directories this agent has actually worked
        //    in, newest first — never against one configured folder, because
        //    the agent is free to work anywhere.
        await resolveRelatives(in: text, result: &result, budget: &budget)
        if result.count > 5 { result = Array(result.prefix(5)) }
        lock.lock(); resolvedByText[text] = result; lock.unlock()
        if result != guesses {
            Diagnostics.log("agent", "path.resolve \(guesses.count)→\(result.count) verified")
        }
        return result
    }

    // MARK: - What the tools already told us

    /// The longest recorded tool path this mention starts with. The agent
    /// wrote "/root/work/Demo Project — rev.0.docx" as a tool argument, so
    /// the reply mentioning it needs no interpretation.
    private static func toolPathHit(for span: String) -> String? {
        lock.lock()
        let recorded = toolPaths
        lock.unlock()
        return recorded
            .filter { span.hasPrefix($0) && $0.split(separator: "/").count > 1 }
            .max { $0.count < $1.count }
    }

    /// Whether a chip may offer a download for this path. An extension is
    /// evidence enough; a name without one costs a single listing to settle
    /// (a directory argument must not be offered as a file).
    private static func noteFileness(of path: String, budget: inout Int) async {
        if !(path as NSString).pathExtension.isEmpty {
            lock.lock(); verifiedFiles.insert(path); lock.unlock()
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let entries = await entries(of: parent, budget: &budget),
              let entry = entries.first(where: { $0.name == name }), !entry.isDirectory
        else { return }
        lock.lock(); verifiedFiles.insert(path); lock.unlock()
    }

    /// A guess that ends in a real extension is whole; one that does not was
    /// cut by the first space in a name and only the host can finish it.
    private static func needsHost(span: String, guesses: [String]) -> Bool {
        guard let guess = guesses.filter({ span.hasPrefix($0) }).max(by: { $0.count < $1.count })
        else { return true }
        let ext = (guess as NSString).pathExtension
        return !(ext.first?.isLetter ?? false)
    }

    // MARK: - Mentions with no root

    /// "work/отчёт.docx", "report.docx" — a name with an extension and no
    /// leading "/". Only worth chasing when we know a directory to try it in.
    private static let relativeRegex = try? NSRegularExpression(
        pattern: #"(?:^|[\s`'"(\[:=*|>])([\p{L}\p{N}_][\p{L}\p{N}._\-]*(?:/[\p{L}\p{N}._\-]+)*\.[A-Za-z][A-Za-z0-9]{0,7})(?![A-Za-z0-9])"#,
        options: [.anchorsMatchLines])

    private static func resolveRelatives(in text: String, result: inout [String],
                                         budget: inout Int) async {
        guard let regex = relativeRegex else { return }
        lock.lock()
        let recorded = toolPaths
        lock.unlock()
        let bases = baseDirectories(besides: result)
        guard !bases.isEmpty || !recorded.isEmpty else { return }

        var handled = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard handled < 3 else { break }
            let lineText = String(line)
            let matches = regex.matches(in: lineText,
                                        range: NSRange(lineText.startIndex..., in: lineText))
            guard !matches.isEmpty else { continue }
            // A line whose rooted path is already resolved needs nothing:
            // its filename tail would only be re-chased as a relative name.
            guard !result.contains(where: { lineText.contains($0) }) else { continue }
            handled += 1

            // A tool named this very file: no request, no ambiguity.
            var settled = false
            for match in matches {
                guard let range = Range(match.range(at: 1), in: lineText) else { continue }
                let candidate = String(lineText[range])
                if result.contains(where: { $0 == candidate || $0.hasSuffix("/" + candidate) }) {
                    settled = true
                    break
                }
                if let hit = recorded.first(where: {
                    ($0.hasPrefix("/") || $0.hasPrefix("~/")) && $0.hasSuffix("/" + candidate)
                }) {
                    merge(hit, from: hit, into: &result)
                    lock.lock(); verifiedFiles.insert(hit); lock.unlock()
                    settled = true
                    break
                }
            }
            if settled { continue }

            // Otherwise try the line against the directories the agent has
            // been working in, starting at each word: a relative name may
            // hold spaces too, and only the host can say where it ends. The
            // listing is cached, so the whole line costs one request per
            // directory.
            let starts = wordStarts(in: lineText)
            search: for base in bases {
                for start in starts {
                    let rest = String(lineText[start...])
                    guard let found = await walk(directory: base, rest: rest, budget: &budget)
                    else { continue }
                    // A relative mention with no extension is prose as far as
                    // anyone can tell; only a real filename earns a chip.
                    guard found.isFile,
                          (found.path as NSString).lastPathComponent.contains(".") else { continue }
                    merge(found.path, from: found.path, into: &result)
                    lock.lock(); verifiedFiles.insert(found.path); lock.unlock()
                    break search
                }
            }
        }
    }

    /// Every word start on a line that could begin a filename — rooted paths
    /// and punctuation excluded, the earliest first so the longest candidate
    /// is tried before its own tail.
    private static func wordStarts(in line: String) -> [String.Index] {
        var starts: [String.Index] = []
        var index = line.startIndex
        var atBoundary = true
        while index < line.endIndex, starts.count < 8 {
            let character = line[index]
            if character.isWhitespace {
                atBoundary = true
            } else {
                if atBoundary, character.isLetter || character.isNumber { starts.append(index) }
                atBoundary = false
            }
            index = line.index(after: index)
        }
        return starts
    }

    /// Where the agent has actually been putting files: the directories of
    /// the paths its tools named, newest first, then the ones this reply
    /// already resolved. No configured "work folder" — it may write into a
    /// different one in the next message.
    private static func baseDirectories(besides resolved: [String]) -> [String] {
        lock.lock()
        let recorded = toolPaths
        lock.unlock()
        var bases: [String] = []
        for path in recorded + resolved where path.hasPrefix("/") || path.hasPrefix("~/") {
            let directory = (path as NSString).deletingLastPathComponent
            guard directory.count > 1, !bases.contains(directory) else { continue }
            bases.append(directory)
            if bases.count >= 4 { break }
        }
        return bases
    }

    // MARK: - The walk

    /// A mention runs from a path root to the end of its line: the line is
    /// the only boundary a filename provably cannot cross.
    private static let mentionRegex = try? NSRegularExpression(
        pattern: #"(?:^|[\s`'"(\[:=*|>])((?:~|/Users|/home|/root|/srv|/mnt|/tmp|/private|/var|/opt|/etc)/[^\n\r]*)"#,
        options: [.anchorsMatchLines])

    /// Mentions worth a listing: only the ones the regex cannot have taken
    /// whole — a span with no space in it needs no host to be read.
    private static func mentions(in text: String) -> [String] {
        guard let regex = mentionRegex else { return [] }
        var spans: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let span = String(text[range])
            guard span.contains(" ") || span.contains("\t") else { continue }
            guard seen.insert(span).inserted else { continue }
            spans.append(span)
            if spans.count >= 5 { break }
        }
        return spans
    }

    /// Walks one mention against the real filesystem. `budget` is spent per
    /// directory listing, so a deeply nested name with spaces at several
    /// levels cannot turn one reply into a crawl.
    private static func verify(span: String, budget: inout Int) async -> (path: String, isFile: Bool)? {
        // Everything before the first space is unambiguous; the name that
        // may contain spaces starts at that run's LAST component. Sliced on
        // the span itself — a String's indices are its own, and the head is
        // a different String even when it reads the same.
        guard let firstSpace = span.rangeOfCharacter(from: .whitespaces) else { return nil }
        let head = span[span.startIndex..<firstSpace.lowerBound]
        guard let lastSlash = head.lastIndex(of: "/") else { return nil }
        var directory = String(span[span.startIndex..<lastSlash])
        let rest = String(span[span.index(after: lastSlash)...])
        if directory.isEmpty { directory = "/" }
        return await walk(directory: directory, rest: rest, budget: &budget)
    }

    /// The walk itself, shared by rooted mentions and relative ones: match
    /// the longest real entry the text starts with, descend while that entry
    /// is a directory the text keeps going into.
    private static func walk(directory: String, rest: String,
                             budget: inout Int) async -> (path: String, isFile: Bool)? {
        var directory = directory
        var rest = rest
        for _ in 0..<6 {
            guard let entries = await self.entries(of: directory, budget: &budget) else { return nil }
            // Longest name first: a directory holding both "Demo" and
            // "Demo Project — rev.0.docx" must answer with the longer one.
            let match = entries
                .filter { rest.range(of: $0.name, options: [.anchored]) != nil }
                .max { $0.name.count < $1.name.count }
            guard let match else { return nil }
            let joined = directory.hasSuffix("/") ? directory + match.name : directory + "/" + match.name
            // Anchored range, not dropFirst(count): the host may spell a
            // name decomposed (NFD) where the reply spells it composed, and
            // Swift compares those equal but counts them differently.
            guard let nameRange = rest.range(of: match.name, options: [.anchored]) else { return nil }
            let after = rest[nameRange.upperBound...]
            if match.isDirectory, after.first == "/" {
                directory = joined
                rest = String(after.dropFirst())
                continue
            }
            return (joined, !match.isDirectory)
        }
        return nil
    }

    /// Directory entries from whichever host owns the path: this Mac when
    /// the gateway is local, the dashboard files API when it is remote.
    /// `budget` is spent only when a listing is actually FETCHED — a cache
    /// hit is free, which is what lets a whole line be tried word by word
    /// against the same directory for the price of one request.
    private static func entries(of directory: String,
                                budget: inout Int) async -> [(name: String, isDirectory: Bool)]? {
        lock.lock()
        let cached = listings[directory]
        lock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < listingTTL { return cached.entries }
        guard budget > 0 else { return nil }
        budget -= 1

        let localPath = directory.hasPrefix("~")
            ? NSHomeDirectory() + directory.dropFirst()
            : directory
        var isDirectory: ObjCBool = false
        var found: [(name: String, isDirectory: Bool)]?
        if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: localPath)) ?? []
            found = names.map { name in
                var sub: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: localPath + "/" + name, isDirectory: &sub)
                return (name, sub.boolValue)
            }
        } else {
            found = await HermesFileCourier.listRemoteDirectory(directory)
        }
        // A failure is cached too, as "no entries": an unreadable or missing
        // directory must be asked ONCE, not once per word the line offers it
        // (the counter caught 8 requests for a single reply).
        let entries = found ?? []
        lock.lock(); listings[directory] = (entries, Date()); lock.unlock()
        return entries
    }

    /// A verified path replaces the guesses THIS mention produced — the
    /// truncated one it extends ("…/work/Demo" → the whole name) and the
    /// over-eager one that swallowed the sentence after it — and is
    /// appended when the guess missed the mention entirely. Scoped to the
    /// span so a path mentioned on another line keeps its own chip.
    private static func merge(_ verified: String, from span: String, into paths: inout [String]) {
        var kept: [String] = []
        var insertAt: Int?
        for path in paths {
            let fromThisMention = span.hasPrefix(path)
                && (path == verified || verified.hasPrefix(path) || path.hasPrefix(verified))
            if fromThisMention {
                if insertAt == nil { insertAt = kept.count }
                continue
            }
            kept.append(path)
        }
        kept.insert(verified, at: insertAt ?? kept.count)
        paths = kept
    }
}

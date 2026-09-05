import Foundation

// Contract test for HermesSteer (the mid-turn follow-up frame and how the
// user's words come back out of a Hermes tool row / a pending_steer).
// Compiled STANDALONE together with the contract file — no app target:
//   swiftc HermesSteer.swift SteerContractTest.swift -o test
//   ./test shared/fixtures/steer-frame.json
// Run via scripts/test-attach-note.sh, which also runs the Kotlin twin.

struct Fixture: Decodable {
    struct Framed: Decodable { let name: String; let text: String; let wire: String }
    struct Pieces: Decodable { let name: String; let text: String; let pieces: [String] }
    struct Unframed: Decodable { let name: String; let text: String; let words: String }
    struct Extract: Decodable { let name: String; let content: String; let texts: [String] }
    let frame: String
    let framed: [Framed]
    let pieces: [Pieces]
    let unframed: [Unframed]
    let extract: [Extract]
}

@main
struct SteerContractTest {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            print("usage: steer-test <steer-frame.json>")
            exit(2)
        }
        let fixture: Fixture
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
            fixture = try JSONDecoder().decode(Fixture.self, from: data)
        } catch {
            print("FIXTURE LOAD FAILED: \(error)")
            exit(2)
        }

        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String) {
            if condition {
                print("  ok \(name)")
            } else {
                failures += 1
                print("  FAIL \(name): \(detail())")
            }
        }
        // `{frame}` in a case stands for the fixture's frame.
        func expand(_ text: String) -> String {
            text.replacingOccurrences(of: "{frame}", with: fixture.frame)
        }

        print("frame:")
        check("pinned", HermesSteer.frame == fixture.frame,
              "swift frame differs from the fixture:\n\(HermesSteer.frame)")

        print("framed:")
        for testCase in fixture.framed {
            let wire = HermesSteer.framed(testCase.text)
            check(testCase.name, wire == expand(testCase.wire), "got \(String(reflecting: wire))")
            // Round-trip: the words come back out alone.
            check("\(testCase.name) (round-trip)", HermesSteer.pieces(wire) == [testCase.text],
                  "got \(HermesSteer.pieces(wire))")
        }

        print("pieces:")
        for testCase in fixture.pieces {
            let pieces = HermesSteer.pieces(expand(testCase.text))
            check(testCase.name, pieces == testCase.pieces, "got \(pieces)")
        }

        print("unframed:")
        for testCase in fixture.unframed {
            let words = HermesSteer.unframed(expand(testCase.text))
            check(testCase.name, words == testCase.words, "got \(String(reflecting: words))")
        }

        print("extract:")
        for testCase in fixture.extract {
            let texts = HermesSteer.extract(fromToolContent: expand(testCase.content))
            check(testCase.name, texts == testCase.texts, "got \(texts)")
        }

        if failures > 0 {
            print("swift: \(failures) failure(s)")
            exit(1)
        }
        print("swift: all green")
    }
}

import Foundation

// Contract test for AgentAttachNote (the cross-device attach-note format).
// Compiled STANDALONE together with the contract file — no app target:
//   swiftc AgentAttachNote.swift AttachNoteContractTest.swift -o test
//   ./test shared/fixtures/attach-note.json
// Run via scripts/test-attach-note.sh, which also runs the Kotlin twin.

struct Fixture: Decodable {
    struct Compose: Decodable {
        let name: String
        let paths: [String]
        let note: String
    }
    struct Split: Decodable {
        let name: String
        let text: String
        let display: String
        let paths: [String]
    }
    struct Matching: Decodable {
        let name: String
        let text: String
        let normalized: String
    }
    let compose: [Compose]
    let split: [Split]
    let matching: [Matching]
}

@main
struct AttachNoteContractTest {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            print("usage: attach-note-test <attach-note.json>")
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

        print("compose:")
        for testCase in fixture.compose {
            let note = AgentAttachNote.compose(paths: testCase.paths)
            check(testCase.name, note == testCase.note,
                  "got \(String(reflecting: note))")
            // Round-trip: a composed note must split back losslessly.
            let split = AgentAttachNote.split(note)
            check("\(testCase.name) (round-trip)",
                  split.display.isEmpty && split.paths == testCase.paths,
                  "got display=\(String(reflecting: split.display)) paths=\(split.paths)")
        }

        print("split:")
        for testCase in fixture.split {
            let result = AgentAttachNote.split(testCase.text)
            check(testCase.name,
                  result.display == testCase.display && result.paths == testCase.paths,
                  "got display=\(String(reflecting: result.display)) paths=\(result.paths)")
        }

        print("matching:")
        for testCase in fixture.matching {
            let normalized = AgentAttachNote.normalizedForMatching(testCase.text)
            check(testCase.name, normalized == testCase.normalized,
                  "got \(String(reflecting: normalized))")
        }

        if failures > 0 {
            print("\(failures) FAILURE(S)")
            exit(1)
        }
        print("all green")
    }
}

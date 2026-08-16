import Foundation

// Contract test for AgentPlaudNote (how an agent refers to a Plaud recording).
// Compiled STANDALONE together with the contract file — no app target:
//   swiftc AgentPlaudNote.swift PlaudNoteContractTest.swift -o test
//   ./test shared/fixtures/plaud-note.json
// Run via scripts/test-attach-note.sh, which also runs the Kotlin twin.

struct PlaudFixture: Decodable {
    struct Ref: Decodable, Equatable {
        let fileID: String
        let title: String
    }
    struct Compose: Decodable {
        let name: String
        let references: [Ref]
        let note: String
    }
    struct Split: Decodable {
        let name: String
        let text: String
        let display: String
        let references: [Ref]
    }
    let compose: [Compose]
    let split: [Split]
}

@main
struct PlaudNoteContractTest {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            print("usage: plaud-note-test <plaud-note.json>")
            exit(2)
        }
        let fixture: PlaudFixture
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
            fixture = try JSONDecoder().decode(PlaudFixture.self, from: data)
        } catch {
            print("fixture unreadable: \(error)")
            exit(2)
        }

        var failures = 0
        func check(_ name: String, _ what: String, _ got: String, _ want: String) {
            guard got != want else { return }
            failures += 1
            print("FAIL [\(name)] \(what)\n  got:  \(got.debugDescription)\n  want: \(want.debugDescription)")
        }

        for testCase in fixture.compose {
            let refs = testCase.references.map {
                AgentPlaudNote.Reference(fileID: $0.fileID, title: $0.title)
            }
            check(testCase.name, "compose", AgentPlaudNote.compose(refs), testCase.note)
        }

        for testCase in fixture.split {
            let (display, references) = AgentPlaudNote.split(testCase.text)
            check(testCase.name, "display", display, testCase.display)
            let got = references.map { PlaudFixture.Ref(fileID: $0.fileID, title: $0.title) }
            if got != testCase.references {
                failures += 1
                print("FAIL [\(testCase.name)] references\n  got:  \(got)\n  want: \(testCase.references)")
            }
        }

        let total = fixture.compose.count + fixture.split.count
        if failures == 0 {
            print("swift: all green (\(total) cases)")
        } else {
            print("swift: \(failures) failure(s) across \(total) cases")
            exit(1)
        }
    }
}

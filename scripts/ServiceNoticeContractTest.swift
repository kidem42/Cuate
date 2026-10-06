import Foundation

// Contract test for HermesServiceNotice (gateway service reports rendered as
// collapsed cards) and HermesContinuationFrame (Cuate's continuation turn).
// Compiled STANDALONE together with the contract files — no app target:
//   swiftc HermesServiceNotice.swift HermesContinuationFrame.swift ServiceNoticeContractTest.swift -o test
//   ./test shared/fixtures/service-notices.json
// Run via scripts/test-attach-note.sh, which also runs the Kotlin twin.

struct Fixture: Decodable {
    struct Notice: Decodable {
        let name: String
        let text: String
        let kind: String
        let tasks: Int
        let ok: Int
        let fail: Int
        let duration: String?
        let exit: String?
        let firstLabel: String?
        let firstGoal: String?
    }
    struct Continuation: Decodable {
        let wire: String
        let matches: [String]
        let others: [String]
    }
    let notices: [Notice]
    let notNotices: [String]
    let continuation: Continuation
}

@main
struct ServiceNoticeContractTest {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            print("usage: service-notice-test <service-notices.json>")
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
                print("  ok   \(name)")
            } else {
                failures += 1
                print("  FAIL \(name): \(detail())")
            }
        }

        for c in fixture.notices {
            check("\(c.name): detected", HermesServiceNotice.isNotice(c.text), "isNotice false")
            check("\(c.name): not a continuation", !HermesContinuationFrame.isContinuation(c.text), "matched")
            guard let notice = HermesServiceNotice.parse(c.text) else {
                check("\(c.name): parsed", false, "parse returned nil")
                continue
            }
            let kind = notice.kind == .delegation ? "delegation" : "process"
            check("\(c.name): kind", kind == c.kind, "\(kind) != \(c.kind)")
            check("\(c.name): tasks", notice.tasks.count == c.tasks, "\(notice.tasks.count) != \(c.tasks)")
            check("\(c.name): tally", notice.okCount == c.ok && notice.failCount == c.fail,
                  "\(notice.okCount)/\(notice.failCount) != \(c.ok)/\(c.fail)")
            check("\(c.name): duration", notice.durationText == c.duration,
                  "\(notice.durationText ?? "nil") != \(c.duration ?? "nil")")
            check("\(c.name): exit", notice.exitText == c.exit,
                  "\(notice.exitText ?? "nil") != \(c.exit ?? "nil")")
            if let label = c.firstLabel {
                check("\(c.name): first label", notice.tasks.first?.label == label,
                      "\(notice.tasks.first?.label ?? "nil") != \(label)")
            }
            if let goal = c.firstGoal {
                check("\(c.name): first goal", notice.tasks.first?.goal == goal,
                      "\(notice.tasks.first?.goal ?? "nil") != \(goal)")
            }
            // The card must never eat content: every task body or the free
            // body together carry text whenever the report had any.
            let carried = notice.tasks.contains { !$0.body.isEmpty || !$0.goal.isEmpty }
                || !(notice.body ?? "").isEmpty || !notice.metaLines.isEmpty
            check("\(c.name): content carried", carried, "nothing to show")
        }
        for text in fixture.notNotices {
            check("plain: \(text.prefix(30))", !HermesServiceNotice.isNotice(text)
                  && HermesServiceNotice.parse(text) == nil, "treated as a notice")
        }
        check("continuation wire pinned", HermesContinuationFrame.wire == fixture.continuation.wire,
              HermesContinuationFrame.wire)
        for text in fixture.continuation.matches {
            check("continuation: \(text.prefix(30))", HermesContinuationFrame.isContinuation(text), "not matched")
            check("continuation is no notice: \(text.prefix(20))", !HermesServiceNotice.isNotice(text), "notice")
        }
        for text in fixture.continuation.others {
            check("not continuation: \(text.prefix(30))", !HermesContinuationFrame.isContinuation(text), "matched")
        }

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("service notices: all cases pass")
    }
}

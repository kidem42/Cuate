#!/usr/bin/env python3
"""Window planning and deferred navigation contracts, no application launch/build."""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parent.parent
engine = (root/'Cuate/Views/Transcript/TranscriptEngine.swift').read_text()
controller = engine[engine.index('final class TranscriptController {'):engine.index('final class TranscriptEngineView:')]
harness = '''import Foundation
class TranscriptEngineView {
 var jumps: [String] = []
 var isPinnedToBottom = false
 func scrollToBottom(animated: Bool) { jumps.append("bottom") }
 func scrollTo(id: String, animated: Bool) { jumps.append(id) }
 func isRowVisible(id: String) -> Bool { false }
 func hasRow(id: String) -> Bool { false }
}
enum Diagnostics { static func log(_ category: String, _ event: String) {} }
''' + controller + '''
@main struct Test {
 static func main() {
  for total in [1, 10, 30, 31, 120, 500] {
   for target in 0..<total {
    let range = TranscriptNavigationWindow.range(target: target, total: total, pageSize: 30)!
    precondition(range.contains(target) && range.count <= 30 && range.lowerBound >= 0 && range.upperBound <= total)
   }
  }
  precondition(TranscriptNavigationWindow.range(target: -1, total: 10, pageSize: 30) == nil)
  precondition(TranscriptNavigationWindow.nearestPin(positions: [90, 40, 5], anchor: 43) == 1)
  precondition(TranscriptNavigationWindow.nearestPin(positions: [90, 40, 5], anchor: 99) == 0)
  precondition(TranscriptNavigationWindow.nearestPin(positions: [90, 40, 5], anchor: 1) == 2)
  precondition(TranscriptNavigationWindow.nearestPin(positions: [], anchor: 1) == nil)
  let controller = TranscriptController(), engine = TranscriptEngineView()
  controller.engine = engine
  controller.requestNavigation(id: "old-pin", conversation: "A")
  controller.didApplyRows(ids: ["recent"], conversation: "A")
  precondition(engine.jumps.isEmpty)
  controller.didApplyRows(ids: ["old-pin"], conversation: "A")
  precondition(engine.jumps == ["old-pin"])
  controller.didApplyRows(ids: ["old-pin"], conversation: "A")
  precondition(engine.jumps.count == 1)
  controller.requestNavigation(id: "old-pin", conversation: "A")
  controller.didApplyRows(ids: ["old-pin"], conversation: "B")
  controller.didApplyRows(ids: ["old-pin"], conversation: "A")
  precondition(engine.jumps.count == 1)
  controller.requestNavigation(id: "old-pin", conversation: "A")
  controller.scrollToBottom(animated: false)
  controller.didApplyRows(ids: ["old-pin"], conversation: "A")
  precondition(engine.jumps == ["old-pin", "bottom"])
  controller.requestNavigation(id: "first", conversation: "A")
  controller.requestNavigation(id: "second", conversation: "A")
  controller.didApplyRows(ids: ["first", "second"], conversation: "A")
  precondition(engine.jumps.last == "second")
  print("Pin navigation: window boundaries, nearest selection and deferred commands passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='cuate-pins-') as folder:
    folder = Path(folder)
    (folder/'Test.swift').write_text(harness)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
                    *(['-sdk',os.environ['SDKROOT']] if 'SDKROOT' in os.environ else []),
                    '-module-cache-path', str(folder/'cache'), str(folder/'Test.swift'),
                    str(root/'Cuate/Views/Transcript/TranscriptNavigationWindow.swift'),
                    '-o',str(folder/'test')],check=True)
    subprocess.run([str(folder/'test')],check=True)

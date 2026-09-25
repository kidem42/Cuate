#!/usr/bin/env python3
"""SwiftData migration + durable aggregates against a temporary synthetic store."""
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
sdk = ['-sdk', os.environ['SDKROOT']] if os.environ.get('SDKROOT') else []
with tempfile.TemporaryDirectory(prefix='cuate-ledger-') as folder:
    temp = Path(folder)
    old_model = (root/'scripts/fixtures/SpendLedgerLegacy.swift').read_text()
    writer = '''import Foundation
import SwiftData
'''+old_model+'''
@main struct Seed {
 static func main() throws {
  let schema = Schema([SDSpendRecord.self])
  let config = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("CuateSpend.store"))
  let container = try ModelContainer(for: schema, configurations: config)
  let context = ModelContext(container)
  context.insert(SDSpendRecord(kindRaw: "chat", provider: "openai", model: "fixture", inputTokens: 100, outputTokens: 20, costUSD: 0.25))
  try context.save()
 }
}
'''
    (temp/'Old.swift').write_text(writer)
    core = (root/'Cuate/Providers/ProviderCore.swift').read_text()
    usage = core[core.index('nonisolated struct TokenUsage'):core.index('/// A source a server-side')]
    support = '''import Foundation
'''+usage+r'''
enum ProviderID: String { case hermes }
enum Diagnostics { static func log(_ category: String, _ event: String) { FileHandle.standardError.write(Data((category + " " + event + "\n").utf8)) } }
enum PricingCatalog { static func refreshIfStale() {} }
func L(_ key: String) -> String { key }
enum ChatStore {
 nonisolated static var baseDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
}
@main struct Verify {
 @MainActor static func main() async throws {
  let store = SpendStore.shared
  // Cold lightweight migration can exceed 100 ms. Wait for the observable
  // load result instead of assuming the background queue has already finished.
  for _ in 0..<500 {
   if store.currentMonthAvg != nil && !store.selectedMonthRecords.isEmpty { break }
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  if CommandLine.arguments.count > 2 {
   // Remove ONLY the synthetic table after ModelContainer opens to force save errors.
   let fault = Process()
   fault.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
   fault.arguments = [ChatStore.baseDirectory.appendingPathComponent("CuateSpend.store").path,
     "DROP TABLE ZSDSPENDRECORD"]
   try fault.run(); fault.waitUntilExit()
   precondition(fault.terminationStatus == 0)
   store.record(kind: .chat, provider: "openai", model: "failed-save", costUSD: 1)
   for _ in 0..<2000 {
    if store.failedWrites > 0 { break }
    try await Task.sleep(nanoseconds: 20_000_000)
   }
    precondition(store.failedWrites == 1, "failed save is surfaced after bounded retries")
   precondition(store.sessionUSD == 0 && store.currentMonthUSD == 1.5, "failed save does not inflate totals")
   precondition(store.selectedMonthRecords.count == 4, "failed retries do not add records")
   print("Spend save-failure contracts: 3 passed")
   return
  }
  precondition(store.currentMonthUSD == 0.25, "legacy money retained")
  precondition(store.currentMonthAvg?.input == 100, "legacy token counts retained")
  store.record(kind: .chat, provider: "openai", model: "fixture", usage: TokenUsage(inputTokens: 300, outputTokens: 40), costUSD: 0.5, operationID: "same-answer", usageState: "complete", costBasis: "catalog", completionState: "completed")
  store.record(kind: .chat, provider: "openai", model: "fixture", usage: TokenUsage(inputTokens: 500, outputTokens: 60), costUSD: 0.75, operationID: "same-answer", usageState: "complete", costBasis: "catalog", completionState: "completed")
  store.record(kind: .translation, provider: "openai", model: "fixture", costUSD: nil, operationID: "failed-translation", usageState: "missing", costBasis: "unknown", completionState: "failed")
  for _ in 0..<100 {
   if store.selectedMonthRecords.count == 4 { break }
   try await Task.sleep(nanoseconds: 20_000_000)
  }
  precondition(store.selectedMonthRecords.count == 4, "each request saved once")
  precondition(store.currentMonthUSD == 1.5 && store.sessionUSD == 1.25, "durable monthly/session totals")
  precondition(store.currentMonthAvg?.count == 2 && store.currentMonthAvg?.input == 450 && store.currentMonthAvg?.output == 60, "average groups requests by answer")
  precondition(store.selectedMonthRecords.first?.usageState == nil, "legacy provenance remains unknown")
  precondition(store.selectedMonthRecords.last?.usageState == "missing", "missing usage metadata persists")
  precondition(store.failedWrites == 0, "saves acknowledged")
  print("Spend ledger contracts: 8 passed")
 }
}
'''
    (temp/'Support.swift').write_text(support)
    def compile(name, sources):
        subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor',
                        *sdk,'-module-cache-path',str(temp/'cache'),'-o',str(temp/name),*map(str,sources)],check=True)
    compile('seed',[temp/'Old.swift'])
    subprocess.run([str(temp/'seed'),str(temp)],check=True)
    compile('verify',[root/'Cuate/Models/SpendLedger.swift',temp/'Support.swift'])
    subprocess.run([str(temp/'verify'),str(temp)],check=True)

    failed_save = subprocess.run([str(temp/'verify'),str(temp),'fail-save'], capture_output=True, text=True)
    if failed_save.returncode:
        print(failed_save.stdout + failed_save.stderr)
        failed_save.check_returncode()
    print('Spend save-failure contracts: 3 passed')

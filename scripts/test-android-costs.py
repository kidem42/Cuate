"""Isolated Kotlin contracts using cached dependencies; never builds/launches the app."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'android/app/src/main/kotlin/com/aispotlight/android'
CACHE = Path.home() / '.gradle/caches/modules-2/files-2.1'
def jar(module): return sorted((CACHE / module).glob('*/*/*.jar'))[-1]
def run(args): subprocess.run(list(map(str,args)), cwd=ROOT, check=True)
with tempfile.TemporaryDirectory(prefix='cuate-android-costs-') as tmp:
 t=Path(tmp)
 compiler=jar('org.jetbrains.kotlin/kotlin-compiler-embeddable')
 stdlib=next((CACHE/'org.jetbrains.kotlin/kotlin-stdlib'/compiler.parent.parent.name).glob('*/*.jar'))
 deps=[compiler,stdlib]+[jar(m) for m in ['org.jetbrains.intellij.deps/trove4j','org.jetbrains.kotlin/kotlin-reflect','org.jetbrains.kotlin/kotlin-script-runtime','org.jetbrains/annotations','org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm']]
 libs=[stdlib]+[jar(m) for m in ['org.jetbrains/annotations','org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm','com.squareup.okhttp3/okhttp','com.squareup.okio/okio-jvm','org.json/json']]
 libs += [Path.home()/'Library/Android/sdk/platforms/android-36/android.jar']
 # Keep the actual provider model/usage types and image conversion; replace only network I/O.
 core=(SRC/'core/ProviderCore.kt').read_text()
 (t/'ProviderCore.kt').write_text(core[:core.index('object HttpClient {')]+'fun newCallID(): String = UUID.randomUUID().toString()\n')
 # Entity mapping needs Room; domain types used here are copied verbatim, no mapping changes tested.
 models=(SRC/'data/ChatModels.kt').read_text()
 (t/'ChatModels.kt').write_text(models[:models.index('fun MessageEntity.toDomain')])
 pricing=(SRC/'providers/PricingCatalog.kt').read_text()
 start=pricing.index('data class ModelPricing('); end=pricing.index('\n/**',start)
 (t/'ModelPricing.kt').write_text('package com.aispotlight.android.providers\nimport com.aispotlight.android.core.TokenUsage\n'+pricing[start:end])
 sources=[t/'ProviderCore.kt',t/'ChatModels.kt',t/'ModelPricing.kt']+[SRC/p for p in ['core/DocumentPreflight.kt','providers/OpenAICompatibleProvider.kt','providers/AnthropicProvider.kt','providers/GeminiProvider.kt','providers/PromptCache.kt','providers/AccountingProvider.kt','providers/ProviderRegistry.kt','chat/ContextCompressionPolicy.kt','chat/PinNavigationPolicy.kt','chat/ChatService.kt','data/SpendLedger.kt','data/SpendAnalytics.kt']]
 # Exercise the actual ViewModel compression coordinator against a transactional fake DAO.
 vm=(SRC/'chat/ChatViewModel.kt').read_text()
 method=vm[vm.index('    private val compressingConversations'):vm.index('\n}\n',vm.index('    private val compressingConversations'))]
 method=method.replace('private suspend fun runCompression','suspend fun runCompression')
 (t/'CompressionCoordinator.kt').write_text("""package com.aispotlight.android.chat
import androidx.room.withTransaction
import com.aispotlight.android.data.*
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
class CompressionCoordinator {
 val dao = AppDatabase.chats
 var activeConversation: Conversation? = null
 val _activeConversationId = MutableStateFlow<String?>(null)
 fun getApplication() = android.content.Context()
 private suspend fun withAttachments(rows: List<ChatMessage>) = rows
"""+method+'\n}\n')
 sources += [t/'CompressionCoordinator.kt']
 settings=(SRC/'settings/AppSettings.kt').read_text()
 controls=settings[settings.index('    /** Global trigger'):settings.index('    // MARK: - Chat provider & models')]
 (t/'CompressionSettingsHarness.kt').write_text('package com.aispotlight.android.settings\nimport kotlinx.coroutines.flow.MutableStateFlow\nimport kotlinx.coroutines.flow.StateFlow\nclass CompressionSettingsHarness(val prefs: android.content.SharedPreferences) {\n'+controls+'\n}')
 sources += [t/'CompressionSettingsHarness.kt']
 pin_methods=vm[vm.index('    private suspend fun ensurePinLoaded'):vm.index('    // MARK: Files of the chat')]
 (t/'PinLoader.kt').write_text("""package com.aispotlight.android.chat
import com.aispotlight.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
class PinLoader {
 val dao = AppDatabase.chats
 val _activeConversationId = MutableStateFlow<String?>("A")
 val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
 val _hasOlderMessages = MutableStateFlow(true)
 val windowSize = 120
 var totalMessageCount = 0
 private suspend fun withAttachments(rows: List<ChatMessage>) = rows
"""+pin_methods+'\n}')
 sources += [t/'PinLoader.kt']
 sources += list((ROOT/'scripts/fixtures/android-costs').glob('*.kt'))
 sources += [ROOT/'scripts/AndroidCostsContractTest.kt']
 java='/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java'
 run([java,'-cp',os.pathsep.join(map(str,deps)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',os.pathsep.join(map(str,libs)),*sources,'-d',t/'tests.jar'])
 run([java,'-cp',os.pathsep.join(map(str,[t/'tests.jar',*libs])),'AndroidCostsContractTestKt'])

 # UI and database declarations receive a syntax parse, not an application compile check.
 run([java,'-cp',os.pathsep.join(map(str,deps)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
      '-no-stdlib','-no-reflect','-classpath',os.pathsep.join(map(str,deps)),
      ROOT/'scripts/KotlinSyntaxCheck.kt','-d',t/'parser.jar'])
 run([java,'-cp',os.pathsep.join(map(str,[t/'parser.jar',*deps])), 'KotlinSyntaxCheckKt',*sorted(SRC.rglob('*.kt'))])

# Execute the actual migration SQL against an existing ledger, without Room/code generation.
import sqlite3, re, xml.etree.ElementTree as ET
schema=(SRC/'data/Db.kt').read_text()
old=schema[schema.index('private val MIGRATION_2_3'):schema.index('private val MIGRATION_3_4')]
create=''.join(re.findall(r'"([^"\n]*)"',old.split('db.execSQL(',2)[1]))
db=sqlite3.connect(':memory:'); db.execute(create)
db.execute("INSERT INTO spend_records VALUES ('old',123,'chat','openai','legacy',100,10,20,0,0,0,0.4,1)")
block=schema[schema.index('private val MIGRATION_5_6'):schema.index('        fun get(context: Context)')]
columns=re.findall(r'"(\w+)"',re.search(r'listOf\((.*?)\)',block).group(1))
statement=re.search(r'db.execSQL\("(.*?)"\)',block).group(1)
for column in columns: db.execute(statement.replace('$column',column))
assert db.execute('SELECT costUSD,inputTokens,operationID,usageState,costBasis,completionState FROM spend_records').fetchone()==(0.4,100,None,None,None,None)
assert 'version = 6' in schema and 'MIGRATION_4_5, MIGRATION_5_6' in schema
for locale in ['values','values-ru','values-es']:
 strings=ET.parse(ROOT/'android/app/src/main/res'/locale/'strings.xml').getroot()
 names=[item.attrib.get('name') for item in strings]
 assert len(names)==len(set(names)), locale
 for key in ['compression_title','compression_threshold','compression_apply','compression_hint','costs_receipt_quality','costs_avg_request','costs_purpose_totals']:
  assert key in names, (locale,key)
print('Ledger migration and en/es/ru resources passed')

query=re.search(r'@Query\("([^"\n]+)"\)\n    suspend fun messagesBefore',schema).group(1)
db.execute('CREATE TABLE messages (id TEXT PRIMARY KEY, conversationId TEXT, timestamp INTEGER)')
db.executemany('INSERT INTO messages VALUES (?,?,?)', [('a','A',1),('b','A',2),('c','A',2),('d','B',1)])
assert [row[0] for row in db.execute(query, {'conversationId':'A','beforeId':'c','limit':120})]==['b','a']
assert [row[0] for row in db.execute(query, {'conversationId':'A','beforeId':'b','limit':120})]==['a']
print('Stable pagination SQL preserves equal timestamps and conversation scope')

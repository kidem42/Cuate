#!/usr/bin/env python3
"""Isolated contracts: actual provider serializers/parsers + accounting decorator.
No application target, network, keys, user data or installed application.
Only HTTP and host settings/persistence are replaced by deterministic test seams.
"""
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='cuate-accounting-') as temp:
    temp = Path(temp)
    core = (root/'Cuate/Providers/ProviderCore.swift').read_text()
    core = core[:core.index('// MARK: - HTTP helpers')]
    pricing = (root/'Cuate/Providers/PricingCatalog.swift').read_text().split('// MARK: - Catalog')[0]
    spend = (root/'Cuate/Models/SpendLedger.swift').read_text()
    kind = spend[spend.index('enum SpendKind'):spend.index('@Model')]
    (temp/'Contracts.swift').write_text(core+'\n'+pricing+'\n'+kind)
    chat = (root/'Cuate/Providers/ChatService.swift').read_text()
    state = chat[chat.index('    @MainActor\n    final class TurnState'):chat.index('    // MARK: - Streaming with the agent loop')]
    loop = chat[chat.index('    @MainActor\n    static func streamReply'):chat.index('    /// OpenRouter answers')]
    # Keep loop logic byte-for-byte; only unrelated host/UI declarations are stubbed.
    (temp/'ChatLoop.swift').write_text('import Foundation\nenum ChatService {\n'
        + 'enum ChatEvent { case text(String), status(String), toolContext(String), attachments([String]) }\n'
        + state.replace('fileprivate', '') + loop + '\n}')
    sources = ['Cuate/Providers/OllamaCompatibility.swift', 'Cuate/Providers/ProviderUsage.swift',
               'Cuate/Providers/ProviderPromptCache.swift', 'Cuate/Providers/OpenAIPromptCache.swift', 'Cuate/Providers/OpenAICompatibleProvider.swift',
               'Cuate/Providers/AnthropicProvider.swift', 'Cuate/Providers/GeminiProvider.swift',
               'Cuate/Providers/AccountingProvider.swift', 'scripts/ProviderAccountingContractTest.swift']
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',
                    *(['-sdk', os.environ['SDKROOT']] if os.environ.get('SDKROOT') else []),
                    '-module-cache-path', str(temp/'cache'), '-o',str(temp/'test'),
                    str(temp/'Contracts.swift'), str(temp/'ChatLoop.swift'), *[str(root/s) for s in sources]], check=True)
    subprocess.run([str(temp/'test')],check=True)

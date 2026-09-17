"""Run isolated Swift/Kotlin/Python contracts, never an application build.

Kotlin uses kotlinc or a cached compiler; no Gradle task or dependency download.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from hermes.approval_client_fixture import swift_fixture, kotlin_settings_fixture

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


with tempfile.TemporaryDirectory(prefix="cuate-approval-tests-") as temporary:
    temp = Path(temporary)
    run(["xcrun", "swiftc", "-module-cache-path", temp / "swift-cache", "-swift-version", "5",
         "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
         "-warnings-as-errors", "Cuate/Addons/HermesAddon/HermesApproval.swift",
         "Cuate/Addons/HermesAddon/HermesApprovalHTTP.swift", "scripts/HermesApprovalContractTest.swift", "-o", temp / "swift-test"])
    run([temp / "swift-test"])
    fixture = temp / "SwiftIntegration.swift"
    fixture.write_text(swift_fixture(ROOT))
    run(["xcrun", "swiftc", "-module-cache-path", temp / "swift-cache", "-swift-version", "5",
         "-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
         "-warnings-as-errors", "Cuate/Addons/HermesAddon/HermesApproval.swift", fixture,
         "-o", temp / "swift-integration"])
    run([temp / "swift-integration"])
    cache = Path.home() / ".gradle/caches/modules-2/files-2.1"
    java_home = Path(os.environ.get("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home"))
    java = str(java_home / "bin/java") if (java_home / "bin/java").exists() else shutil.which("java")
    libraries = []
    for module in ("com.squareup.okhttp3/okhttp", "com.squareup.okio/okio-jvm", "org.json/json",
                   "org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm"):
        libraries.append(sorted((cache / module).glob("*/*/*.jar"))[-1])
    kotlin_sources = ["android/app/src/main/kotlin/com/aispotlight/android/hermes/HermesApproval.kt",
                      "android/app/src/main/kotlin/com/aispotlight/android/hermes/HermesTransport.kt",
                      "scripts/HermesApprovalContractTest.kt", "scripts/HermesApprovalTransportContractTest.kt"]
    scoped_settings = temp / "RunSettings.kt"
    scoped_settings.write_text(kotlin_settings_fixture(ROOT))
    kotlin_sources.append(scoped_settings)
    kotlin_sources += list((ROOT / "scripts/fixtures/hermes-approval").glob("*.kt"))
    if shutil.which("kotlinc"):
        run(["kotlinc", *kotlin_sources, "-classpath", os.pathsep.join(map(str, libraries)),
             "-include-runtime", "-d", temp / "kotlin.jar"])
        run([java, "-cp", os.pathsep.join(map(str, [temp / "kotlin.jar", *libraries])), "HermesApprovalContractTestKt"])
    else:
        compilers = sorted(cache.glob("org.jetbrains.kotlin/kotlin-compiler-embeddable/*/*/*.jar"))
        if not compilers:
            raise SystemExit("Standalone Kotlin compiler unavailable; no application build was attempted")
        compiler = compilers[-1]
        version = compiler.parent.parent.name
        stdlib = next(cache.glob("org.jetbrains.kotlin/kotlin-stdlib/" + version + "/*/*.jar"))
        dependencies = [compiler, stdlib]
        for module in ("org.jetbrains.kotlin/kotlin-reflect", "org.jetbrains.kotlin/kotlin-script-runtime",
                       "org.jetbrains.intellij.deps/trove4j", "org.jetbrains/annotations",
                       "org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm"):
            jars = sorted((cache / module).glob("*/*/*.jar"))
            if jars:
                dependencies.append(jars[-1])
        run([java, "-cp", os.pathsep.join(map(str, dependencies)), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
             "-no-stdlib", "-no-reflect", "-classpath", os.pathsep.join(map(str, [stdlib, *libraries])),
             *kotlin_sources, "-d", temp / "kotlin.jar"])
        run([java, "-cp", os.pathsep.join(map(str, [temp / "kotlin.jar", stdlib, *libraries])), "HermesApprovalContractTestKt"])
    run([sys.executable, "-B", "scripts/HermesApprovalContractTest.py"])
    run([sys.executable, "-B", "scripts/HermesSkillsCatalogContractTest.py"])

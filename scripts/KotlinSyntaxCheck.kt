import java.io.File
import org.jetbrains.kotlin.cli.jvm.compiler.KotlinCoreEnvironment
import org.jetbrains.kotlin.cli.jvm.compiler.EnvironmentConfigFiles
import org.jetbrains.kotlin.config.CompilerConfiguration
import org.jetbrains.kotlin.com.intellij.openapi.util.Disposer
import org.jetbrains.kotlin.com.intellij.psi.PsiErrorElement
import org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil
import org.jetbrains.kotlin.psi.KtPsiFactory

/** Parser only: no application symbols are compiled, generated or linked. */
fun main(args: Array<String>) {
    val disposable = Disposer.newDisposable()
    try {
        val environment = KotlinCoreEnvironment.createForProduction(disposable, CompilerConfiguration(), EnvironmentConfigFiles.JVM_CONFIG_FILES)
        val factory = KtPsiFactory(environment.project, false)
        for (path in args) {
            val file = factory.createFile(File(path).name, File(path).readText())
            val errors = PsiTreeUtil.collectElementsOfType(file, PsiErrorElement::class.java)
            check(errors.isEmpty()) { "$path: ${errors.joinToString { it.errorDescription }}" }
        }
        println("Kotlin syntax: ${args.size} files passed (parser only)")
    } finally { Disposer.dispose(disposable) }
}

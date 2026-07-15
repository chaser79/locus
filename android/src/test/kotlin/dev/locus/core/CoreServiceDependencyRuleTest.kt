package dev.locus.core

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreServiceDependencyRuleTest {
    @Test
    fun `core does not import concrete service implementations`() {
        val coreDirectory = File("src/main/kotlin/dev/locus/core")
        assertTrue(
            "Core source directory was not found: ${coreDirectory.absolutePath}",
            coreDirectory.isDirectory,
        )

        val violations = coreDirectory.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file ->
                file.readLines().withIndex()
                    .filter { (_, line) -> line.trim().startsWith("import dev.locus.service.") }
                    .map { (index, line) -> "${file.name}:${index + 1}: ${line.trim()}" }
                    .asSequence()
            }
            .toList()

        assertTrue(
            "Core must depend on service gateways, not concrete services:\n${violations.joinToString("\n")}",
            violations.isEmpty(),
        )
    }
}

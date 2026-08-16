package dev.locus.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineBindingRegistryTest {
    @Test
    fun `unknown owner release does not affect active engine binding`() {
        val registry = EngineBindingRegistry<String>()
        val secondEngine = Any()

        registry.claim(secondEngine, "second")

        assertFalse(registry.release(Any()))
        assertEquals("second", registry.current())
    }

    @Test
    fun `active owner release restores previous live engine binding`() {
        val registry = EngineBindingRegistry<String>()
        val firstEngine = Any()
        val secondEngine = Any()

        registry.claim(firstEngine, "first")
        registry.claim(secondEngine, "second")

        assertTrue(registry.release(secondEngine))
        assertEquals("first", registry.current())
        assertTrue(registry.release(firstEngine))
        assertNull(registry.current())
    }

    @Test
    fun `stale owner is removed so it cannot be restored later`() {
        val registry = EngineBindingRegistry<String>()
        val firstEngine = Any()
        val secondEngine = Any()

        registry.claim(firstEngine, "first")
        registry.claim(secondEngine, "second")

        assertTrue(registry.release(firstEngine))
        assertEquals("second", registry.current())
        assertTrue(registry.release(secondEngine))
        assertNull(registry.current())
    }

    @Test
    fun `same owner can replace and release its binding`() {
        val registry = EngineBindingRegistry<String>()
        val engine = Any()

        registry.claim(engine, "old")
        registry.claim(engine, "new")

        assertEquals("new", registry.current())
        assertTrue(registry.release(engine))
        assertNull(registry.current())
    }
}

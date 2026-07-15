package dev.locus.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineCallbackBrokerTest {
    @Test
    fun `detach retries newest different engine and ignores late reply`() {
        val registry = EngineBindingRegistry<String>()
        val scheduler = ManualDeadlineScheduler()
        val broker = EngineCallbackBroker(registry, scheduler)
        val firstOwner = Any()
        val secondOwner = Any()
        val replies = mutableMapOf<String, (String) -> Unit>()
        val invocations = mutableListOf<String>()
        val results = mutableListOf<String>()

        registry.claim(firstOwner, "first")
        broker.request(
            invoke = { bridge, reply ->
                invocations += bridge
                replies[bridge] = reply
            },
            fallback = { it("fallback") },
            terminalDefault = { "default" },
            completion = results::add,
        )

        broker.bindingClaimed(registry.claimAndSnapshot(secondOwner, "second"))
        registry.release(firstOwner)
        broker.ownerDetached(firstOwner)

        assertEquals(listOf("first", "second"), invocations)
        replies.getValue("first")("late")
        assertTrue(results.isEmpty())
        replies.getValue("second")("second-result")
        scheduler.runAll()
        assertEquals(listOf("second-result"), results)
    }

    @Test
    fun `deadline retries newer engine before fallback`() {
        val registry = EngineBindingRegistry<String>()
        val scheduler = ManualDeadlineScheduler()
        val broker = EngineCallbackBroker(registry, scheduler)
        val firstOwner = Any()
        val secondOwner = Any()
        val replies = mutableMapOf<String, (String) -> Unit>()
        val invocations = mutableListOf<String>()
        val results = mutableListOf<String>()

        registry.claim(firstOwner, "first")
        broker.request(
            invoke = { bridge, reply ->
                invocations += bridge
                replies[bridge] = reply
            },
            fallback = { it("fallback") },
            terminalDefault = { "default" },
            completion = results::add,
        )
        broker.bindingClaimed(registry.claimAndSnapshot(secondOwner, "second"))

        scheduler.runNext()

        assertEquals(listOf("first", "second"), invocations)
        replies.getValue("second")("second-result")
        replies.getValue("first")("late")
        scheduler.runAll()
        assertEquals(listOf("second-result"), results)
    }

    @Test
    fun `two engine deadlines use fallback exactly once`() {
        val registry = EngineBindingRegistry<String>()
        val scheduler = ManualDeadlineScheduler()
        val broker = EngineCallbackBroker(registry, scheduler)
        val firstOwner = Any()
        val secondOwner = Any()
        val replies = mutableListOf<(String) -> Unit>()
        val invocations = mutableListOf<String>()
        val results = mutableListOf<String>()

        registry.claim(firstOwner, "first")
        broker.request(
            invoke = { bridge, reply ->
                invocations += bridge
                replies += reply
            },
            fallback = { it("fallback") },
            terminalDefault = { "default" },
            completion = results::add,
        )
        broker.bindingClaimed(registry.claimAndSnapshot(secondOwner, "second"))

        scheduler.runNext()
        scheduler.runNext()
        replies.forEach { it("late") }
        scheduler.runAll()

        assertEquals(listOf("first", "second"), invocations)
        assertEquals(listOf("fallback"), results)
    }

    @Test
    fun `same owner replacement invalidates old generation without retrying owner`() {
        val registry = EngineBindingRegistry<String>()
        val scheduler = ManualDeadlineScheduler()
        val broker = EngineCallbackBroker(registry, scheduler)
        val owner = Any()
        lateinit var oldReply: (String) -> Unit
        val invocations = mutableListOf<String>()
        val results = mutableListOf<String>()

        registry.claim(owner, "old")
        broker.request(
            invoke = { bridge, reply ->
                invocations += bridge
                oldReply = reply
            },
            fallback = { it("fallback") },
            terminalDefault = { "default" },
            completion = results::add,
        )

        broker.bindingClaimed(registry.claimAndSnapshot(owner, "replacement"))
        oldReply("late")
        scheduler.runAll()

        assertEquals(listOf("old"), invocations)
        assertEquals(listOf("fallback"), results)
    }

    @Test
    fun `fallback deadline applies terminal default and suppresses late reply`() {
        val registry = EngineBindingRegistry<String>()
        val scheduler = ManualDeadlineScheduler()
        val broker = EngineCallbackBroker(registry, scheduler)
        lateinit var fallbackReply: (String) -> Unit
        val results = mutableListOf<String>()

        broker.request(
            invoke = { _, _ -> error("No engine should be invoked") },
            fallback = { fallbackReply = it },
            terminalDefault = { "default" },
            completion = results::add,
        )

        scheduler.runNext()
        fallbackReply("late")

        assertEquals(listOf("default"), results)
    }

    private class ManualDeadlineScheduler : CallbackDeadlineScheduler {
        private data class ScheduledTask(
            val callback: () -> Unit,
            var cancelled: Boolean = false,
        )

        private val tasks = mutableListOf<ScheduledTask>()

        override fun schedule(
            delayMs: Long,
            callback: () -> Unit,
        ): CallbackDeadlineCancellation {
            assertEquals(10_000L, delayMs)
            val task = ScheduledTask(callback)
            tasks += task
            return CallbackDeadlineCancellation { task.cancelled = true }
        }

        fun runNext() {
            while (tasks.isNotEmpty()) {
                val task = tasks.removeAt(0)
                if (!task.cancelled) {
                    task.callback()
                    return
                }
            }
            error("No active deadline was scheduled")
        }

        fun runAll() {
            while (tasks.any { !it.cancelled }) {
                runNext()
            }
            tasks.clear()
        }
    }
}

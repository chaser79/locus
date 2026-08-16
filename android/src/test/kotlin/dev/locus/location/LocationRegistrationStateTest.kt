package dev.locus.location

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationRegistrationStateTest {
    @Test
    fun `initial registration becomes active only after commit`() {
        val state = LocationRegistrationState<Any>()
        val candidate = Any()

        val operation = state.begin(candidate)

        assertNull(state.active)
        assertTrue(state.commit(operation.token, candidate).accepted)
        assertSame(candidate, state.active)
    }

    @Test
    fun `failed replacement preserves active registration`() {
        val state = LocationRegistrationState<Any>()
        val active = Any()
        val first = state.begin(active)
        state.commit(first.token, active)

        val replacement = Any()
        val operation = state.begin(replacement)

        assertTrue(state.reject(operation.token, replacement))
        assertSame(active, state.active)
    }

    @Test
    fun `new operation rejects late completion from superseded candidate`() {
        val state = LocationRegistrationState<Any>()
        val first = Any()
        val firstOperation = state.begin(first)
        val second = Any()
        val secondOperation = state.begin(second)

        assertSame(first, secondOperation.superseded)
        assertFalse(state.commit(firstOperation.token, first).accepted)
        assertTrue(state.commit(secondOperation.token, second).accepted)
        assertSame(second, state.active)
    }

    @Test
    fun `stop invalidates pending operation and returns every callback to remove`() {
        val state = LocationRegistrationState<Any>()
        val active = Any()
        val first = state.begin(active)
        state.commit(first.token, active)
        val pending = Any()
        val pendingOperation = state.begin(pending)

        val removed = state.stop()

        assertTrue(removed.any { it === active })
        assertTrue(removed.any { it === pending })
        assertNull(state.active)
        assertFalse(state.commit(pendingOperation.token, pending).accepted)
    }
}

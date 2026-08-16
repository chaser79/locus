package dev.locus.core

internal fun interface CallbackDeadlineCancellation {
    fun cancel()
}

internal fun interface CallbackDeadlineScheduler {
    fun schedule(delayMs: Long, callback: () -> Unit): CallbackDeadlineCancellation
}

/**
 * Gives engine-scoped Dart callbacks process-owned completion semantics.
 *
 * A Flutter engine may detach after native code selects its bridge but before
 * Dart replies. Flutter drops replies for a dead messenger, so every request is
 * bounded, tied to the selected owner/generation, retried once on a different
 * live engine, and then completed through the caller's existing fallback.
 */
internal class EngineCallbackBroker<T : Any>(
    private val bindings: EngineBindingRegistry<T>,
    private val deadlineScheduler: CallbackDeadlineScheduler,
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    private val lock = Any()
    private val pending = mutableMapOf<Long, PendingOperation>()
    private var nextRequestId = 0L

    fun <R> request(
        invoke: (T, (R) -> Unit) -> Unit,
        fallback: ((R) -> Unit) -> Unit,
        terminalDefault: () -> R,
        completion: (R) -> Unit,
    ) {
        val operation = synchronized(lock) {
            nextRequestId += 1
            Operation(
                requestId = nextRequestId,
                invoke = invoke,
                fallback = fallback,
                terminalDefault = terminalDefault,
                completion = completion,
            ).also { pending[nextRequestId] = it }
        }
        operation.start()
    }

    fun ownerDetached(owner: Any) {
        val affected = synchronized(lock) {
            pending.values.filter { it.isOwnedBy(owner) }
        }
        affected.forEach { it.ownerDetached(owner) }
    }

    /**
     * Invalidates an attempt that captured an older bridge generation for the
     * same owner. The owner remains excluded from retry: a replacement on the
     * same engine is not proof that its messenger is a different live route.
     */
    fun bindingClaimed(binding: EngineBindingSnapshot<T>) {
        val affected = synchronized(lock) {
            pending.values.filter {
                it.isOlderGeneration(binding.owner, binding.generation)
            }
        }
        affected.forEach {
            it.bindingReplaced(binding.owner, binding.generation)
        }
    }

    private interface PendingOperation {
        fun isOwnedBy(owner: Any): Boolean
        fun isOlderGeneration(owner: Any, generation: Long): Boolean
        fun ownerDetached(owner: Any)
        fun bindingReplaced(owner: Any, generation: Long)
    }

    private inner class Operation<R>(
        private val requestId: Long,
        private val invoke: (T, (R) -> Unit) -> Unit,
        private val fallback: ((R) -> Unit) -> Unit,
        private val terminalDefault: () -> R,
        private val completion: (R) -> Unit,
    ) : PendingOperation {
        private val attemptedOwners = mutableListOf<Any>()
        private var activeBinding: EngineBindingSnapshot<T>? = null
        private var activeToken = 0L
        private var deadline: CallbackDeadlineCancellation? = null
        private var completed = false
        private var fallbackStarted = false

        fun start() {
            advanceFromEngine(expectedToken = null)
        }

        override fun isOwnedBy(owner: Any): Boolean = synchronized(lock) {
            !completed && activeBinding?.owner === owner
        }

        override fun isOlderGeneration(owner: Any, generation: Long): Boolean = synchronized(lock) {
            !completed &&
                activeBinding?.let {
                    it.owner === owner && it.generation < generation
                } == true
        }

        override fun ownerDetached(owner: Any) {
            val token = synchronized(lock) {
                activeBinding?.takeIf { it.owner === owner }?.let { activeToken }
            } ?: return
            advanceFromEngine(token)
        }

        override fun bindingReplaced(owner: Any, generation: Long) {
            val token = synchronized(lock) {
                activeBinding?.takeIf {
                    it.owner === owner && it.generation < generation
                }?.let { activeToken }
            } ?: return
            advanceFromEngine(token)
        }

        private fun advanceFromEngine(expectedToken: Long?) {
            val transition = synchronized(lock) {
                if (completed || fallbackStarted) return
                if (expectedToken != null && expectedToken != activeToken) return
                val previousDeadline = deadline
                deadline = null
                activeBinding = null
                activeToken += 1
                Transition(
                    token = activeToken,
                    exclusions = attemptedOwners.toList(),
                    previousDeadline = previousDeadline,
                )
            }
            transition.previousDeadline?.cancel()

            val next = if (transition.exclusions.size < MAX_ENGINE_ATTEMPTS) {
                bindings.currentSnapshot(excludingOwners = transition.exclusions)
            } else {
                null
            }
            if (next == null) {
                beginFallback(transition.token)
            } else {
                beginEngineAttempt(next, transition.token)
            }
        }

        private fun beginEngineAttempt(
            binding: EngineBindingSnapshot<T>,
            transitionToken: Long,
        ) {
            val shouldInvoke = synchronized(lock) {
                if (completed || fallbackStarted || transitionToken != activeToken) {
                    return@synchronized false
                }
                attemptedOwners += binding.owner
                activeBinding = binding
                true
            }
            if (!shouldInvoke) return
            if (!bindings.contains(binding)) {
                advanceFromEngine(transitionToken)
                return
            }
            installDeadline(transitionToken) { advanceFromEngine(transitionToken) }
            val isCurrent = synchronized(lock) {
                !completed &&
                    transitionToken == activeToken &&
                    activeBinding == binding
            }
            if (!isCurrent) return
            try {
                invoke(binding.value) { value -> completeIfCurrent(transitionToken, value) }
            } catch (_: RuntimeException) {
                advanceFromEngine(transitionToken)
            }
        }

        private fun beginFallback(transitionToken: Long) {
            val shouldInvoke = synchronized(lock) {
                if (completed || fallbackStarted || transitionToken != activeToken) {
                    return@synchronized false
                }
                fallbackStarted = true
                true
            }
            if (!shouldInvoke) return
            installDeadline(transitionToken) {
                completeIfCurrent(transitionToken, terminalDefault())
            }
            try {
                fallback { value -> completeIfCurrent(transitionToken, value) }
            } catch (_: RuntimeException) {
                completeIfCurrent(transitionToken, terminalDefault())
            }
        }

        private fun installDeadline(token: Long, onDeadline: () -> Unit) {
            val cancellation = deadlineScheduler.schedule(timeoutMs, onDeadline)
            synchronized(lock) {
                if (completed || token != activeToken) {
                    cancellation.cancel()
                } else {
                    deadline = cancellation
                }
            }
        }

        private fun completeIfCurrent(token: Long, value: R) {
            val callback = synchronized(lock) {
                if (completed || token != activeToken) return
                completed = true
                deadline?.cancel()
                deadline = null
                activeBinding = null
                pending.remove(requestId)
                completion
            }
            callback(value)
        }

    }

    private data class Transition(
        val token: Long,
        val exclusions: List<Any>,
        val previousDeadline: CallbackDeadlineCancellation?,
    )

    private companion object {
        const val DEFAULT_TIMEOUT_MS = 10_000L
        const val MAX_ENGINE_ATTEMPTS = 2
    }
}

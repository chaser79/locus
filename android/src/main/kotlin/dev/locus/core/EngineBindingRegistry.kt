package dev.locus.core

/**
 * Stores process-wide bindings in most-recently-claimed order.
 *
 * Flutter creates one plugin instance per engine, while Locus keeps one native
 * container per process. An older engine may therefore detach after a newer
 * engine has claimed the container. Releasing by owner prevents that stale
 * callback from clearing the newer engine's binding. When the active engine
 * releases its binding, the most recent engine that is still listening is
 * restored automatically.
 */
internal class EngineBindingRegistry<T : Any> {
    private val lock = Any()
    private val bindings = mutableListOf<Binding<T>>()
    private var nextGeneration = 0L

    fun claim(owner: Any, value: T) {
        claimAndSnapshot(owner, value)
    }

    internal fun claimAndSnapshot(owner: Any, value: T): EngineBindingSnapshot<T> =
        synchronized(lock) {
            bindings.removeAll { it.owner === owner }
            nextGeneration += 1
            Binding(owner, value, nextGeneration).also(bindings::add).snapshot()
        }

    fun release(owner: Any): Boolean = synchronized(lock) {
        bindings.removeAll { it.owner === owner }
    }

    fun current(): T? = synchronized(lock) { bindings.lastOrNull()?.value }

    fun currentSnapshot(excludingOwners: List<Any> = emptyList()): EngineBindingSnapshot<T>? =
        synchronized(lock) {
            bindings.lastOrNull { binding ->
                excludingOwners.none { excluded -> excluded === binding.owner }
            }?.snapshot()
        }

    fun contains(snapshot: EngineBindingSnapshot<T>): Boolean = synchronized(lock) {
        bindings.any {
            it.owner === snapshot.owner && it.generation == snapshot.generation
        }
    }

    private data class Binding<T : Any>(
        val owner: Any,
        val value: T,
        val generation: Long,
    ) {
        fun snapshot() = EngineBindingSnapshot(owner, value, generation)
    }
}

internal data class EngineBindingSnapshot<T : Any>(
    val owner: Any,
    val value: T,
    val generation: Long,
)

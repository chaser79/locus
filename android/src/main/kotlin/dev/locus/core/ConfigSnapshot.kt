package dev.locus.core

import org.json.JSONArray
import org.json.JSONObject

internal enum class PersistedConfigStatus {
    ABSENT,
    VALID,
    CORRUPT,
}

internal data class DecodedPersistedConfig(
    val status: PersistedConfigStatus,
    val values: Map<String, Any> = emptyMap(),
    val error: Exception? = null,
)

internal fun decodePersistedConfig(
    serialized: String?,
    decoder: (String) -> Map<String, Any>,
): DecodedPersistedConfig {
    if (serialized == null) {
        return DecodedPersistedConfig(PersistedConfigStatus.ABSENT)
    }
    return try {
        DecodedPersistedConfig(
            status = PersistedConfigStatus.VALID,
            values = decoder(serialized),
        )
    } catch (error: Exception) {
        DecodedPersistedConfig(
            status = PersistedConfigStatus.CORRUPT,
            error = error,
        )
    }
}

internal fun parseConfigSnapshot(serialized: String): Map<String, Any> {
    return JSONObject(serialized).toMap()
}

private fun JSONObject.toMap(): Map<String, Any> {
    val map = mutableMapOf<String, Any>()
    keys().forEach { key ->
        when (val value = get(key)) {
            is JSONArray -> map[key] = value.toList()
            is JSONObject -> map[key] = value.toMap()
            JSONObject.NULL -> Unit
            else -> map[key] = value
        }
    }
    return map
}

private fun JSONArray.toList(): List<Any> {
    val list = mutableListOf<Any>()
    for (index in 0 until length()) {
        when (val value = get(index)) {
            is JSONArray -> list.add(value.toList())
            is JSONObject -> list.add(value.toMap())
            JSONObject.NULL -> Unit
            else -> list.add(value)
        }
    }
    return list
}

internal fun patchNotificationContent(
    config: Map<String, Any>,
    title: String?,
    text: String?,
): Map<String, Any> {
    if (title == null && text == null) return config

    val patched = HashMap(config)
    val notification = (config["notification"] as? Map<*, *>)
        ?.entries
        ?.mapNotNull { (key, value) ->
            val stringKey = key as? String ?: return@mapNotNull null
            value?.let { stringKey to it }
        }
        ?.toMap()
        ?.toMutableMap()
        ?: mutableMapOf()
    if (title != null) notification["title"] = title
    if (text != null) notification["text"] = text
    patched["notification"] = notification
    return patched
}

internal fun mergeConfigSnapshot(
    current: Map<String, Any>,
    incoming: Map<String, Any>,
): Map<String, Any> {
    val merged = HashMap(current)
    merged.putAll(incoming)

    val incomingNotification = incoming["notification"] as? Map<*, *>
    if (incomingNotification != null) {
        val currentNotification = current["notification"] as? Map<*, *>
        val nested = mutableMapOf<String, Any>()
        currentNotification?.forEach { (key, value) ->
            if (key is String && value != null) nested[key] = value
        }
        incomingNotification.forEach { (key, value) ->
            if (key is String && value != null) nested[key] = value
        }
        merged["notification"] = nested
    }

    return merged
}

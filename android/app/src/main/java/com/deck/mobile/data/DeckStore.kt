package com.deck.mobile.data

import android.content.Context
import com.deck.mobile.model.BrowserLink
import com.deck.mobile.model.DeckApp
import com.deck.mobile.model.DeckSlot
import com.deck.mobile.model.Endpoint
import com.deck.mobile.model.LinkSlot
import com.deck.mobile.model.SLOT_COUNT
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class DeckConfig(
    val endpoint: Endpoint?,
    val slots: List<DeckSlot>,
    val links: List<LinkSlot>,
)

class DeckStore(context: Context) {
    private val file = File(context.filesDir, "deck.json")
    private val iconDir = File(context.filesDir, "icons").apply { mkdirs() }
    var revision: Long = 0
        private set

    fun load(): DeckConfig {
        if (!file.exists()) return DeckConfig(endpoint = null, slots = emptySlots(), links = emptyLinks())
        return try {
            parse(JSONObject(file.readText()))
        } catch (_: Exception) {
            DeckConfig(endpoint = null, slots = emptySlots(), links = emptyLinks())
        }
    }

    fun save(config: DeckConfig) {
        val slots = JSONArray()
        config.slots.forEach { slot ->
            val item = JSONObject()
            item.put("key", slot.key)
            slot.app?.let { app ->
                item.put("id", app.id)
                item.put("name", app.name)
            }
            slots.put(item)
        }
        val root = JSONObject()
        root.put("host", config.endpoint?.host.orEmpty())
        root.put("port", config.endpoint?.port ?: 8765)
        root.put("token", config.endpoint?.token.orEmpty())
        root.put("slots", slots)
        val links = JSONArray()
        config.links.forEach { slot ->
            val item = JSONObject()
            item.put("key", slot.key)
            slot.link?.let { link ->
                item.put("title", link.title)
                item.put("url", link.url)
            }
            links.put(item)
        }
        root.put("links", links)
        root.put("revision", revision)
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(root.toString(2))
        if (!tmp.renameTo(file)) {
            file.writeText(root.toString(2))
            tmp.delete()
        }
    }

    fun iconFile(appId: String): File {
        val safe = appId.replace(Regex("[^A-Za-z0-9._-]"), "_").take(180)
        return File(iconDir, "$safe.png")
    }

    fun setRevision(value: Long) {
        revision = value
    }

    fun customIconFile(key: String): File {
        val safe = key.replace(Regex("[^A-Za-z0-9._-]"), "_").take(180)
        return File(iconDir, "custom_$safe.png")
    }

    private fun parse(root: JSONObject): DeckConfig {
        val host = root.optString("host").trim()
        val port = root.optInt("port", 8765)
        val token = root.optString("token").trim().uppercase()
        val endpoint = if (host.isNotBlank() && token.isNotBlank() && port in 1..65535) {
            Endpoint(host, port, token)
        } else {
            null
        }
        revision = root.optLong("revision")
        return DeckConfig(
            endpoint,
            parseSlots(root.optJSONArray("slots")),
            parseLinks(root.optJSONArray("links")),
        )
    }

    private fun parseLinks(array: JSONArray?): List<LinkSlot> {
        val parsed = mutableListOf<LinkSlot>()
        if (array != null) {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val key = item.optString("key").ifBlank { UUID.randomUUID().toString() }
                val url = item.optString("url")
                val title = item.optString("title")
                val link = if (url.isNotBlank()) {
                    BrowserLink(title.ifBlank { url }, url)
                } else {
                    null
                }
                parsed += LinkSlot(key, link)
            }
        }
        return (parsed.take(SLOT_COUNT) + emptyLinks()).take(SLOT_COUNT)
    }

    private fun parseSlots(array: JSONArray?): List<DeckSlot> {
        val parsed = mutableListOf<DeckSlot>()
        if (array != null) {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val key = item.optString("key").ifBlank { UUID.randomUUID().toString() }
                val id = item.optString("id")
                val name = item.optString("name")
                val app = if (id.isNotBlank()) DeckApp(id, name.ifBlank { id }) else null
                parsed += DeckSlot(key, app)
            }
        }
        return (parsed.take(SLOT_COUNT) + emptySlots()).take(SLOT_COUNT)
    }

    private fun emptySlots(): List<DeckSlot> =
        List(SLOT_COUNT) { DeckSlot(key = UUID.randomUUID().toString()) }

    private fun emptyLinks(): List<LinkSlot> =
        List(SLOT_COUNT) { LinkSlot(key = UUID.randomUUID().toString()) }
}

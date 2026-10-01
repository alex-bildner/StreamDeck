package com.deck.mobile.data

import com.deck.mobile.model.BrowserLink
import com.deck.mobile.model.DeckApp
import com.deck.mobile.model.DeckSlot
import com.deck.mobile.model.Endpoint
import com.deck.mobile.model.HostInfo
import com.deck.mobile.model.LinkSlot
import com.deck.mobile.model.Net
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

class CompanionApi {
    private val client = OkHttpClient.Builder()
        .connectTimeout(4, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build()

    private val jsonType = "application/json; charset=utf-8".toMediaType()

    fun health(endpoint: Endpoint): Net<HostInfo> {
        return when (val net = call(endpoint, "/api/health")) {
            is Net.Fail -> net
            is Net.Ok -> {
                val parsed = runCatching { JSONObject(net.value) }.getOrNull()
                val name = parsed?.optString("hostname").orEmpty()
                if (name.isBlank()) {
                    Net.Fail("Resposta inválida do notebook.")
                } else {
                    Net.Ok(HostInfo(name, parsed?.optLong("iconStamp") ?: 0L))
                }
            }
        }
    }

    fun apps(endpoint: Endpoint): Net<List<DeckApp>> {
        return when (val net = call(endpoint, "/api/apps")) {
            is Net.Fail -> net
            is Net.Ok -> {
                val parsed = runCatching {
                    val array = JSONArray(net.value)
                    buildList {
                        for (index in 0 until array.length()) {
                            val item = array.optJSONObject(index) ?: continue
                            val id = item.optString("id")
                            val name = item.optString("name")
                            if (id.isNotBlank() && name.isNotBlank()) add(DeckApp(id, name))
                        }
                    }
                }
                parsed.fold(
                    onSuccess = { Net.Ok(it) },
                    onFailure = { Net.Fail("A lista de apps veio incompleta.") },
                )
            }
        }
    }

    fun launch(endpoint: Endpoint, id: String): Net<String> {
        val body = JSONObject().put("id", id).toString()
        return when (val net = call(endpoint, "/api/launch", body)) {
            is Net.Fail -> net
            is Net.Ok -> Net.Ok(runCatching { JSONObject(net.value).optString("name") }.getOrDefault(""))
        }
    }

    fun fetchDeck(endpoint: Endpoint): Net<RemoteDeck> {
        return when (val net = call(endpoint, "/api/deck")) {
            is Net.Fail -> net
            is Net.Ok -> parseDeck(net.value)?.let { Net.Ok(it) } ?: Net.Fail("O deck do celular veio incompleto.")
        }
    }

    fun pushDeck(
        endpoint: Endpoint,
        base: Long,
        slots: List<DeckSlot>,
        links: List<LinkSlot>,
        customKeys: Set<String>,
    ): Net<Long> {
        val body = JSONObject()
            .put("base", base)
            .put("slots", shortcutsJson(slots, customKeys))
            .put("links", linksJson(links, customKeys))
            .toString()
        val request = Request.Builder()
            .url(base(endpoint) + "/api/deck")
            .header("X-Deck-Token", endpoint.token)
            .header("Accept", "application/json")
            .post(body.toRequestBody(jsonType))
            .build()
        return try {
            client.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (response.code == 409) return Net.Fail("conflito")
                if (response.code == 401) return Net.Fail("Código incorreto.")
                if (!response.isSuccessful) return Net.Fail("Não consegui salvar os atalhos no Mac.")
                val revision = runCatching { JSONObject(text).optLong("revision") }.getOrDefault(-1L)
                if (revision < 0) Net.Fail("Resposta inválida do notebook.") else Net.Ok(revision)
            }
        } catch (_: IOException) {
            Net.Fail("Não encontrei o Mac.")
        }
    }

    fun uploadPhoneIcon(endpoint: Endpoint, key: String, png: ByteArray): Net<Unit> {
        val encoded = URLEncoder.encode(key, Charsets.UTF_8.name()).replace("+", "%20")
        val request = Request.Builder()
            .url(base(endpoint) + "/api/phone-icon/" + encoded)
            .header("X-Deck-Token", endpoint.token)
            .post(png.toRequestBody("image/png".toMediaType()))
            .build()
        return try {
            client.newCall(request).execute().use { response ->
                if (response.code == 401) return Net.Fail("Código incorreto.")
                if (!response.isSuccessful) return Net.Fail("Não consegui enviar o ícone.")
                Net.Ok(Unit)
            }
        } catch (_: IOException) {
            Net.Fail("Não encontrei o Mac.")
        }
    }

    fun downloadPhoneIcon(endpoint: Endpoint, key: String, dest: File): Net<File> {
        val encoded = URLEncoder.encode(key, Charsets.UTF_8.name()).replace("+", "%20")
        val request = Request.Builder()
            .url(base(endpoint) + "/api/phone-icon/" + encoded)
            .header("X-Deck-Token", endpoint.token)
            .header("Accept", "image/png")
            .build()
        return try {
            client.newCall(request).execute().use { response ->
                if (response.code == 404) return Net.Fail("Sem ícone.")
                if (response.code == 401) return Net.Fail("Código incorreto.")
                if (!response.isSuccessful) return Net.Fail("Não consegui baixar o ícone.")
                val bytes = response.body?.bytes() ?: return Net.Fail("Ícone vazio.")
                if (bytes.size < 8 || bytes[0] != PNG_SIGNATURE) return Net.Fail("Ícone inválido.")
                dest.parentFile?.mkdirs()
                dest.writeBytes(bytes)
                Net.Ok(dest)
            }
        } catch (_: IOException) {
            Net.Fail("Não encontrei o Mac.")
        }
    }

    fun openUrl(endpoint: Endpoint, url: String): Net<Unit> {
        val body = JSONObject().put("url", url).toString()
        return when (val net = call(endpoint, "/api/open-url", body)) {
            is Net.Fail -> net
            is Net.Ok -> Net.Ok(Unit)
        }
    }

    fun downloadIcon(endpoint: Endpoint, id: String, dest: File): Net<File> {
        val encoded = URLEncoder.encode(id, Charsets.UTF_8.name()).replace("+", "%20")
        val request = Request.Builder()
            .url(base(endpoint) + "/api/icons/" + encoded)
            .header("X-Deck-Token", endpoint.token)
            .header("Accept", "image/png")
            .build()
        return try {
            client.newCall(request).execute().use { response ->
                if (response.code == 401) return Net.Fail("Código incorreto.")
                if (!response.isSuccessful) return Net.Fail("Não consegui baixar o ícone.")
                val bytes = response.body?.bytes() ?: return Net.Fail("Ícone vazio.")
                if (bytes.size < 8 || bytes[0] != PNG_SIGNATURE) return Net.Fail("Ícone inválido.")
                dest.parentFile?.mkdirs()
                val tmp = File(dest.parentFile, dest.name + ".tmp")
                tmp.writeBytes(bytes)
                if (!tmp.renameTo(dest)) {
                    dest.writeBytes(bytes)
                    tmp.delete()
                }
                Net.Ok(dest)
            }
        } catch (_: IOException) {
            Net.Fail("Não consegui baixar o ícone. O notebook está acessível?")
        }
    }

    private fun shortcutsJson(slots: List<DeckSlot>, customKeys: Set<String>): JSONArray {
        val array = JSONArray()
        slots.forEach { slot ->
            val item = JSONObject()
                .put("key", slot.key)
                .put("custom", customKeys.contains(slot.key))
            slot.app?.let { app ->
                item.put("id", app.id)
                item.put("name", app.name)
            }
            array.put(item)
        }
        return array
    }

    private fun linksJson(links: List<LinkSlot>, customKeys: Set<String>): JSONArray {
        val array = JSONArray()
        links.forEach { slot ->
            val item = JSONObject()
                .put("key", slot.key)
                .put("custom", customKeys.contains(slot.key))
            slot.link?.let { link ->
                item.put("title", link.title)
                item.put("url", link.url)
            }
            array.put(item)
        }
        return array
    }

    private fun parseDeck(text: String): RemoteDeck? {
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        val revision = root.optLong("revision")
        return RemoteDeck(
            revision,
            parseRemoteSlots(root.optJSONArray("slots")),
            parseRemoteLinks(root.optJSONArray("links")),
            customKeys(root.optJSONArray("slots")) + customKeys(root.optJSONArray("links")),
        )
    }

    private fun customKeys(array: JSONArray?): Set<String> {
        if (array == null) return emptySet()
        return buildSet {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                if (item.optBoolean("custom")) {
                    val key = item.optString("key")
                    if (key.isNotBlank()) add(key)
                }
            }
        }
    }

    private fun parseRemoteSlots(array: JSONArray?): List<DeckSlot> {
        if (array == null) return emptyList()
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val key = item.optString("key")
                if (key.isBlank()) continue
                val id = item.optString("id")
                val name = item.optString("name")
                val app = if (id.isNotBlank()) DeckApp(id, name.ifBlank { id }) else null
                add(DeckSlot(key, app))
            }
        }
    }

    private fun parseRemoteLinks(array: JSONArray?): List<LinkSlot> {
        if (array == null) return emptyList()
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val key = item.optString("key")
                if (key.isBlank()) continue
                val url = item.optString("url")
                val title = item.optString("title")
                val link = if (url.isNotBlank()) BrowserLink(title.ifBlank { url }, url) else null
                add(LinkSlot(key, link))
            }
        }
    }

    private fun call(endpoint: Endpoint, path: String, body: String? = null): Net<String> {
        val builder = Request.Builder()
            .url(base(endpoint) + path)
            .header("X-Deck-Token", endpoint.token)
            .header("Accept", "application/json")
        if (body != null) {
            builder.post(body.toRequestBody(jsonType))
        }
        return try {
            client.newCall(builder.build()).execute().use { response ->
                val text = response.body?.string().orEmpty()
                if (response.code == 401) return Net.Fail("Código incorreto.")
                if (!response.isSuccessful) {
                    val message = runCatching { JSONObject(text).optString("error") }.getOrNull()
                        ?.takeIf { it.isNotBlank() }
                    return Net.Fail(message ?: "O notebook respondeu com erro (${response.code}).")
                }
                Net.Ok(text)
            }
        } catch (_: IOException) {
            Net.Fail("Não encontrei o Mac. Confira o Wi-Fi e se o app Deck está instalado nele.")
        }
    }

    private fun base(endpoint: Endpoint): String = "http://${endpoint.host}:${endpoint.port}"

    private companion object {
        val PNG_SIGNATURE = 0x89.toByte()
    }
}

data class RemoteDeck(
    val revision: Long,
    val slots: List<DeckSlot>,
    val links: List<LinkSlot>,
    val customKeys: Set<String>,
)

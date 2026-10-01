package com.deck.mobile.ui

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.deck.mobile.data.CompanionApi
import com.deck.mobile.data.DeckConfig
import com.deck.mobile.data.DeckStore
import com.deck.mobile.data.RemoteDeck
import com.deck.mobile.model.BrowserLink
import com.deck.mobile.model.Connection
import com.deck.mobile.model.DeckApp
import com.deck.mobile.model.DeckSlot
import com.deck.mobile.model.Endpoint
import com.deck.mobile.model.LinkSlot
import com.deck.mobile.model.Net
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max

class DeckViewModel(app: Application) : AndroidViewModel(app) {
    private val store = DeckStore(app)
    private val api = CompanionApi()
    private val saveMutex = Mutex()
    private val syncMutex = Mutex()
    private val localDirty = AtomicBoolean(false)
    private val saveGeneration = AtomicInteger(0)
    private val iconGate = Semaphore(4)
    private val requestedIcons = mutableSetOf<String>()
    private var appSnapshot: List<DeckSlot>? = null
    private var linkSnapshot: List<LinkSlot>? = null

    private val _slots = MutableStateFlow<List<DeckSlot>>(emptyList())
    val slots: StateFlow<List<DeckSlot>> = _slots.asStateFlow()

    private val _links = MutableStateFlow<List<LinkSlot>>(emptyList())
    val links: StateFlow<List<LinkSlot>> = _links.asStateFlow()

    private val _connection = MutableStateFlow<Connection>(Connection.Checking)
    val connection: StateFlow<Connection> = _connection.asStateFlow()

    private val _apps = MutableStateFlow<List<DeckApp>>(emptyList())
    val apps: StateFlow<List<DeckApp>> = _apps.asStateFlow()

    private val _appsLoading = MutableStateFlow(false)
    val appsLoading: StateFlow<Boolean> = _appsLoading.asStateFlow()

    private val _appsError = MutableStateFlow<String?>(null)
    val appsError: StateFlow<String?> = _appsError.asStateFlow()

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 8)
    val messages: SharedFlow<String> = _messages.asSharedFlow()

    val icons = mutableStateMapOf<String, ImageBitmap>()
    val customIcons = mutableStateMapOf<String, ImageBitmap>()

    var endpoint by mutableStateOf<Endpoint?>(null)
        private set

    private var seenIconStamp: Long? = null

    init {
        val saved = store.load()
        endpoint = saved.endpoint
        _slots.value = saved.slots
        _links.value = saved.links
        _connection.value = if (endpoint == null) Connection.NoHost else Connection.Checking
        saved.slots.forEach { slot ->
            loadCustomIcon(slot.key)
            slot.app?.let { requestIcon(it.id) }
        }
        saved.links.forEach { slot -> loadCustomIcon(slot.key) }
        startPhoneSync()
    }

    fun refreshConnection() {
        val current = endpoint
        if (current == null) {
            _connection.value = Connection.NoHost
            return
        }
        viewModelScope.launch {
            _connection.value = Connection.Checking
            _connection.value = when (val net = withContext(Dispatchers.IO) { api.health(current) }) {
                is Net.Ok -> {
                    noteIconStamp(net.value.iconStamp)
                    Connection.Online(net.value.hostname)
                }
                is Net.Fail -> Connection.Offline(net.message)
            }
        }
    }

    suspend fun connect(address: String, token: String): String? {
        return viewModelScope.async { connectLocked(address, token) }.await()
    }

    private suspend fun connectLocked(address: String, token: String): String? {
        val parsed = parseAddress(address) ?: return "Informe o endereço, por exemplo 192.168.0.10:8765."
        val code = token.trim().uppercase()
        if (code.length < 4) return "Informe o código mostrado no notebook."
        val candidate = Endpoint(parsed.first, parsed.second, code)
        val previous = _connection.value
        _connection.value = Connection.Checking
        return when (val net = withContext(Dispatchers.IO) { api.health(candidate) }) {
            is Net.Ok -> {
                endpoint = candidate
                _connection.value = Connection.Online(net.value.hostname)
                noteIconStamp(net.value.iconStamp)
                persist()
                _slots.value.forEach { slot -> slot.app?.let { requestIcon(it.id) } }
                null
            }
            is Net.Fail -> {
                _connection.value = when (previous) {
                    is Connection.Online -> previous
                    is Connection.Offline -> Connection.Offline(net.message)
                    else -> if (endpoint == null) Connection.NoHost else Connection.Offline(net.message)
                }
                net.message
            }
        }
    }

    fun loadApps() {
        val current = endpoint
        if (current == null) {
            _apps.value = emptyList()
            _appsError.value = "Conecte ao notebook primeiro."
            return
        }
        viewModelScope.launch {
            _appsLoading.value = true
            _appsError.value = null
            when (val net = withContext(Dispatchers.IO) { api.apps(current) }) {
                is Net.Ok -> _apps.value = net.value
                is Net.Fail -> {
                    _apps.value = emptyList()
                    _appsError.value = net.message
                }
            }
            _appsLoading.value = false
        }
    }

    fun requestIcon(id: String) {
        if (id.isBlank() || icons.containsKey(id) || id in requestedIcons) return
        requestedIcons.add(id)
        val current = endpoint
        viewModelScope.launch {
            val bitmap = withContext(Dispatchers.IO) {
                iconGate.withPermit { loadIcon(id, current) }
            }
            if (bitmap != null) {
                icons[id] = bitmap
            } else {
                requestedIcons.remove(id)
            }
        }
    }

    suspend fun assign(index: Int, app: DeckApp): String? {
        return viewModelScope.async { performAssign(index, app) }.await()
    }

    fun clear(index: Int) {
        val slots = _slots.value.toMutableList()
        if (index !in slots.indices) return
        slots[index] = slots[index].copy(app = null)
        _slots.value = slots
        persist()
    }

    fun move(from: Int, to: Int) {
        if (from == to) return
        if (appSnapshot == null) appSnapshot = _slots.value
        val slots = _slots.value.toMutableList()
        if (from !in slots.indices || to !in slots.indices) return
        val item = slots.removeAt(from)
        slots.add(to, item)
        _slots.value = slots
    }

    fun moveLink(from: Int, to: Int) {
        if (from == to) return
        if (linkSnapshot == null) linkSnapshot = _links.value
        val slots = _links.value.toMutableList()
        if (from !in slots.indices || to !in slots.indices) return
        val item = slots.removeAt(from)
        slots.add(to, item)
        _links.value = slots
    }

    fun setLink(index: Int, title: String, url: String): String? {
        val normalized = normalizeWebUrl(url) ?: return "Use um link http ou https, por exemplo site.com."
        if (index !in _links.value.indices) return "Botão inválido."
        val name = title.trim().ifBlank { displayHost(normalized) }
        val slots = _links.value.toMutableList()
        slots[index] = slots[index].copy(link = BrowserLink(name, normalized))
        _links.value = slots
        persist()
        return null
    }

    fun clearLink(index: Int) {
        val slots = _links.value.toMutableList()
        if (index !in slots.indices) return
        slots[index] = slots[index].copy(link = null)
        _links.value = slots
        persist()
    }

    fun cancelReorder() {
        appSnapshot?.let { _slots.value = it }
        linkSnapshot?.let { _links.value = it }
        appSnapshot = null
        linkSnapshot = null
    }

    fun commitReorder() {
        appSnapshot = null
        linkSnapshot = null
        persist()
    }

    fun setSlotIcon(page: Int, index: Int, uri: Uri) {
        val key = slotKey(page, index) ?: return
        viewModelScope.launch {
            val png = withContext(Dispatchers.IO) { encodeIcon(uri) }
            if (png == null) {
                _messages.tryEmit("Não consegui ler essa imagem.")
                return@launch
            }
            val bitmap = withContext(Dispatchers.IO) {
                val file = store.customIconFile(key)
                file.parentFile?.mkdirs()
                file.writeBytes(png)
                BitmapFactory.decodeByteArray(png, 0, png.size)?.asImageBitmap()
            }
            if (bitmap != null) customIcons[key] = bitmap
            localDirty.set(true)
            pushDeck()
        }
    }

    fun clearSlotIcon(page: Int, index: Int) {
        val key = slotKey(page, index) ?: return
        store.customIconFile(key).delete()
        customIcons.remove(key)
        localDirty.set(true)
        viewModelScope.launch { pushDeck() }
    }

    fun hasSlotIcon(page: Int, index: Int): Boolean {
        val key = slotKey(page, index) ?: return false
        return customIcons.containsKey(key)
    }

    private fun slotKey(page: Int, index: Int): String? {
        return if (page == 0) {
            _slots.value.getOrNull(index)?.key
        } else {
            _links.value.getOrNull(index)?.key
        }
    }

    private fun loadCustomIcon(key: String) {
        decodeBitmap(store.customIconFile(key))?.let { customIcons[key] = it }
    }

    private fun noteIconStamp(stamp: Long) {
        val previous = seenIconStamp
        if (previous == stamp) return
        seenIconStamp = stamp
        if (previous != null || stamp > 0L) reloadAppIcons()
    }

    private fun reloadAppIcons() {
        _slots.value.mapNotNull { it.app?.id }.distinct().forEach { id ->
            icons.remove(id)
            requestedIcons.remove(id)
            store.iconFile(id).delete()
            requestIcon(id)
        }
    }

    private fun encodeIcon(uri: Uri): ByteArray? {
        val resolver = getApplication<Application>().contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / sample > 1024 || bounds.outHeight / sample > 1024) sample *= 2
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val longest = max(decoded.width, decoded.height)
        val output = if (longest > 512) {
            val scale = 512f / longest
            Bitmap.createScaledBitmap(decoded, (decoded.width * scale).toInt().coerceAtLeast(1), (decoded.height * scale).toInt().coerceAtLeast(1), true)
        } else {
            decoded
        }
        if (output != decoded) decoded.recycle()
        val bytes = ByteArrayOutputStream()
        output.compress(Bitmap.CompressFormat.PNG, 100, bytes)
        output.recycle()
        return bytes.toByteArray()
    }

    fun persist() {
        localDirty.set(true)
        val generation = saveGeneration.incrementAndGet()
        val snapshot = snapshot()
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                saveMutex.withLock {
                    if (generation != saveGeneration.get()) return@withContext
                    store.save(snapshot)
                }
            }
            if (generation == saveGeneration.get()) pushDeck()
        }
    }

    private fun startPhoneSync() {
        viewModelScope.launch {
            while (true) {
                delay(2500)
                val current = endpoint ?: continue
                val health = withContext(Dispatchers.IO) { api.health(current) }
                if (health is Net.Ok) noteIconStamp(health.value.iconStamp)
                val remote = withContext(Dispatchers.IO) { api.fetchDeck(current) }
                if (remote !is Net.Ok) continue
                val deck = remote.value
                if (deck.revision == 0L) {
                    if (!localDirty.get()) localDirty.set(true)
                    pushDeck()
                    continue
                }
                if (!localDirty.get() && deck.revision > store.revision) {
                    syncMutex.withLock {
                        if (!localDirty.get() && deck.revision > store.revision) applyRemote(deck)
                    }
                }
            }
        }
    }

    private suspend fun pushDeck() {
        val current = endpoint ?: return
        syncMutex.withLock {
            if (!localDirty.get()) return
            val customKeys = customKeys()
            for (key in customKeys) {
                val bytes = store.customIconFile(key).takeIf { it.exists() }?.readBytes() ?: continue
                val uploaded = withContext(Dispatchers.IO) { api.uploadPhoneIcon(current, key, bytes) }
                if (uploaded is Net.Fail) return
            }
            val pushed = withContext(Dispatchers.IO) {
                api.pushDeck(current, store.revision, _slots.value, _links.value, customKeys)
            }
            when (pushed) {
                is Net.Ok -> {
                    store.setRevision(pushed.value)
                    store.save(snapshot())
                    localDirty.set(false)
                }
                is Net.Fail -> {
                    if (pushed.message == "conflito") {
                        val remote = withContext(Dispatchers.IO) { api.fetchDeck(current) }
                        if (remote is Net.Ok && remote.value.revision > 0L) applyRemote(remote.value)
                    }
                }
            }
        }
    }

    private fun hasShortcuts(): Boolean {
        return _slots.value.any { it.app != null } || _links.value.any { it.link != null } || customKeys().isNotEmpty()
    }

    private fun customKeys(): Set<String> {
        return (_slots.value.map { it.key } + _links.value.map { it.key })
            .filter { store.customIconFile(it).exists() }
            .toSet()
    }

    private suspend fun applyRemote(deck: RemoteDeck) {
        store.setRevision(deck.revision)
        _slots.value = deck.slots.ifEmpty { _slots.value }
        _links.value = deck.links.ifEmpty { _links.value }
        store.save(snapshot())
        localDirty.set(false)
        val current = endpoint
        val keys = _slots.value.map { it.key } + _links.value.map { it.key }
        for (key in keys) {
            val file = store.customIconFile(key)
            if (key in deck.customKeys && current != null) {
                val downloaded = withContext(Dispatchers.IO) { api.downloadPhoneIcon(current, key, file) }
                if (downloaded is Net.Ok) loadCustomIcon(key) else customIcons.remove(key)
            } else {
                file.delete()
                customIcons.remove(key)
            }
        }
        _slots.value.forEach { slot -> slot.app?.let { requestIcon(it.id) } }
    }

    fun openLink(index: Int) {
        val url = _links.value.getOrNull(index)?.link?.url ?: return
        val current = endpoint
        if (current == null) {
            _messages.tryEmit("Conecte ao notebook para abrir o link.")
            return
        }
        viewModelScope.launch {
            when (val net = withContext(Dispatchers.IO) { api.openUrl(current, url) }) {
                is Net.Ok -> Unit
                is Net.Fail -> {
                    if (net.message == "Código incorreto.") {
                        _connection.value = Connection.Offline(net.message)
                    }
                    _messages.tryEmit(net.message)
                }
            }
        }
    }

    fun launch(index: Int) {
        val app = _slots.value.getOrNull(index)?.app ?: return
        val current = endpoint
        if (current == null) {
            _messages.tryEmit("Conecte ao notebook para abrir o app.")
            return
        }
        viewModelScope.launch {
            when (val net = withContext(Dispatchers.IO) { api.launch(current, app.id) }) {
                is Net.Ok -> Unit
                is Net.Fail -> {
                    if (net.message == "Código incorreto.") {
                        _connection.value = Connection.Offline(net.message)
                    }
                    _messages.tryEmit(net.message)
                }
            }
        }
    }

    private suspend fun performAssign(index: Int, app: DeckApp): String? {
        val current = endpoint ?: return "Conecte ao notebook primeiro."
        if (index !in _slots.value.indices) return "Botão inválido."
        val dest = store.iconFile(app.id)
        val downloaded = withContext(Dispatchers.IO) {
            if (dest.exists() && dest.length() > 0L) Net.Ok(dest) else api.downloadIcon(current, app.id, dest)
        }
        if (downloaded is Net.Fail) return downloaded.message
        val bitmap = withContext(Dispatchers.IO) { decodeBitmap(dest) }
        if (bitmap != null) icons[app.id] = bitmap
        val slots = _slots.value.toMutableList()
        if (index !in slots.indices) return "Botão inválido."
        slots[index] = slots[index].copy(app = app)
        _slots.value = slots
        persist()
        return null
    }

    private fun loadIcon(id: String, endpoint: Endpoint?): ImageBitmap? {
        val file = store.iconFile(id)
        if (file.exists() && file.length() > 0L) {
            decodeBitmap(file)?.let { return it }
        }
        if (endpoint == null) return null
        return when (api.downloadIcon(endpoint, id, file)) {
            is Net.Fail -> null
            is Net.Ok -> decodeBitmap(file)
        }
    }

    private fun snapshot(): DeckConfig = DeckConfig(endpoint, _slots.value, _links.value)

    private fun decodeBitmap(file: File): ImageBitmap? {
        if (!file.exists() || file.length() == 0L) return null
        return BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap()
    }
}

fun normalizeWebUrl(raw: String): String? {
    var text = raw.trim()
    if (text.isBlank()) return null
    if (!text.contains("://")) text = "https://$text"
    val uri = Uri.parse(text)
    val scheme = uri.scheme?.lowercase()
    if (scheme != "http" && scheme != "https") return null
    if (uri.host.isNullOrBlank()) return null
    return text
}

fun displayHost(url: String): String {
    val host = Uri.parse(url).host.orEmpty().removePrefix("www.")
    return host.ifBlank { url }
}

fun parseAddress(raw: String): Pair<String, Int>? {
    var text = raw.trim().removePrefix("http://").removePrefix("https://").trimEnd('/')
    if (text.isBlank() || text.startsWith("[")) return null
    val colon = text.lastIndexOf(':')
    val host: String
    val port: Int
    if (colon > 0 && text.substring(colon + 1).all { it.isDigit() }) {
        host = text.substring(0, colon)
        port = text.substring(colon + 1).toIntOrNull() ?: return null
    } else {
        host = text
        port = 8765
    }
    if (host.isBlank() || port !in 1..65535) return null
    return host to port
}

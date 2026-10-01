package com.deck.mobile.model

const val SLOT_COUNT = 10

data class DeckApp(
    val id: String,
    val name: String,
)

data class DeckSlot(
    val key: String,
    val app: DeckApp? = null,
)

data class BrowserLink(
    val title: String,
    val url: String,
)

data class LinkSlot(
    val key: String,
    val link: BrowserLink? = null,
)

data class HostInfo(
    val hostname: String,
    val iconStamp: Long,
)

data class Endpoint(
    val host: String,
    val port: Int,
    val token: String,
)

sealed interface Connection {
    data object NoHost : Connection
    data object Checking : Connection
    data class Online(val hostname: String) : Connection
    data class Offline(val message: String) : Connection
}

sealed interface Net<out T> {
    data class Ok<T>(val value: T) : Net<T>
    data class Fail(val message: String) : Net<Nothing>
}

package com.aispotlight.android.chat

import com.aispotlight.android.data.ChatMessage

object PinNavigationPolicy {
    fun ordered(pins: List<ChatMessage>): List<ChatMessage> = pins.sortedByDescending { it.timestamp }
    fun nearest(pins: List<ChatMessage>, anchor: Long?): String? =
        if (anchor == null) pins.firstOrNull()?.id
        else pins.minByOrNull { kotlin.math.abs(it.timestamp - anchor) }?.id
    fun target(pins: List<ChatMessage>, index: Int, visible: Boolean): String =
        pins[if (visible) (index + 1) % pins.size else index].id
}

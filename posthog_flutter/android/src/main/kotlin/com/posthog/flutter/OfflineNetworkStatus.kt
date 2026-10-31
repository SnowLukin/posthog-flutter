package com.posthog.flutter

import com.posthog.internal.PostHogNetworkStatus

/** Always offline. The original status keeps the subscription, so close() still removes it. */
internal class OfflineNetworkStatus(
    private val delegate: PostHogNetworkStatus?,
) : PostHogNetworkStatus {
    override fun isConnected(): Boolean = false

    override fun register(callback: () -> Unit) {
        delegate?.register(callback)
    }

    override fun unregister() {
        delegate?.unregister()
    }
}

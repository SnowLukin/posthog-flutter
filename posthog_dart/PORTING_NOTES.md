# Porting notes

posthog_dart is a hand-port of the `posthog-core` package of
[posthog-js-lite](https://github.com/PostHog/posthog-js-lite), ported from
upstream `main` at commit `1e2e226c59f3c3a63f780d9b61f6d06304f86903`.

Deliberate deviations from posthog-js-lite:

| Behavior | posthog-js-lite | posthog_dart | Why |
| --- | --- | --- | --- |
| Quota-limited `/flags` response | Unsets all cached flags | Keeps serving cached flags; `quota_limited` is reported only when there is no cached value | Parity with posthog-android / posthog-ios |
| Person properties on `identify()` / `capture()` | Not fed into flag evaluation | `$set` / `$set_once` merge into the persisted person properties for flags (`$set` wins) | Parity with the mobile SDKs |
| Default person properties for flags | Not supported | `setDefaultPersonProperties` option plus the `getDefaultPersonPropertiesForFlags()` override; explicitly set properties win | Parity with the mobile SDKs |
| `getFeatureFlag` of an unknown key | `false` once flags are loaded | `null` | posthog_flutter documents `null` for a missing flag; all platforms must answer alike |
| Async init guards | `_initPromise` checked in every accessor | None | Dart construction is synchronous; the object is not observable before the constructor returns |
| Event emitter | Untyped listeners, `'*'` wildcard event | Typed `on(event, listener)` and `onAny(listener)` | Dart has no variadic closures |

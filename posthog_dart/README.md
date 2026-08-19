# posthog_dart

Pure-Dart core of the PostHog SDK: event capture with an offline queue, identify/group/alias, feature flags, and consent handling — no Flutter or native dependency.

Inside this repository it powers the Windows and Linux implementation of `posthog_flutter` (registered via `dartPluginClass`). It can also be used standalone from any Dart VM program (CLI, server) — see [issue #170](https://github.com/PostHog/posthog-flutter/issues/170).

The implementation is a hand-port of [posthog-js-lite](https://github.com/PostHog/posthog-js-lite); deliberate deviations from it are listed in [PORTING_NOTES.md](PORTING_NOTES.md).

## Usage

```dart
import 'package:posthog_dart/posthog_dart.dart';

void main() async {
  final posthog = PostHog(
    '<ph_project_api_key>',
    options: PostHogConfig(host: 'https://us.i.posthog.com'),
    storage: FileStorage('/path/to/app-data/posthog'),
  );

  posthog.capture('event_name', properties: {'plan': 'pro'});

  if (posthog.isFeatureEnabled('my-flag') ?? false) {
    // ...
  }

  await posthog.shutdown();
}
```

`FileStorage` persists the queue, identity, super properties, and the opt-out
flag as a single JSON snapshot (atomic temp-file + rename writes). Pass
`InMemoryStorage` — or any other `PostHogStorage` implementation — when
persistence is not wanted.

## Scope

Included: capture with batching, retries and offline queueing; identify, alias
and groups; person profiles modes; feature flags (`/flags` v2) with payloads and
`$feature_flag_called` tracking; `beforeSend` hooks; opt-out persisted across
restarts.

Not included (native/Flutter-level features): session replay, surveys,
autocapture, error-tracking integrations. The Flutter plugin layers those where
platform support exists.

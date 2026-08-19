import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import 'feature_flag_utils.dart';
import 'posthog_core_stateless.dart';
import 'types.dart';
import 'utils/utils.dart';
import 'uuid.dart';

/// Stateful PostHog client with session management, identity, and feature flags.
///
/// This is the main class that applications interact with. It extends
/// [PostHogCoreStateless] with state management for sessions, identity,
/// feature flags, and person profiles.
///
/// Subclasses must implement [fetch], [getLibraryId], [getLibraryVersion],
/// and [getCustomUserAgent].
abstract class PostHogCore extends PostHogCoreStateless {
  // options
  final bool _sendFeatureFlagEvents;
  final bool _setDefaultPersonProperties;
  final Map<String, bool> _flagCallReported = {};
  final List<BeforeSendCallback>? _beforeSend;

  // internal
  Future<PostHogFlagsResponse?>? _flagsResponseFuture;
  final Duration _sessionExpiration;
  static const Duration _sessionMaxLength = Duration(hours: 24);

  ({
    Completer<PostHogFlagsResponse?> completer,
    bool sendAnonDistinctId
  })? _pendingFlagsRequest;

  // person profiles
  final PostHogPersonProfiles _personProfiles;

  // cache for person properties to avoid duplicate $set events
  String? _cachedPersonProperties;

  PostHogCore(
    super.apiKey, {
    super.options,
    super.storage,
  })  : _sendFeatureFlagEvents = options.sendFeatureFlagEvents,
        _setDefaultPersonProperties = options.setDefaultPersonProperties,
        _sessionExpiration = options.sessionExpiration,
        _personProfiles = options.personProfiles,
        _beforeSend = options.beforeSend;

  void _clearProps() {
    props = null;
    _flagCallReported.clear();
  }

  /// Resets the PostHog state. Clears all persisted properties except the queue
  /// and any properties specified in [propertiesToKeep].
  void reset({List<PostHogPersistedProperty>? propertiesToKeep}) {
    wrap(() {
      final allKeep = [
        PostHogPersistedProperty.queue,
        // Consent must survive identity resets.
        PostHogPersistedProperty.optedOut,
        ...(propertiesToKeep ?? []),
      ];

      _clearProps();
      _cachedPersonProperties = null;

      for (final prop in PostHogPersistedProperty.values) {
        if (!allKeep.contains(prop)) {
          setPersistedProperty(prop, null);
        }
      }

      reloadFeatureFlags();
    });
  }

  @override
  Map<String, Object?> getCommonEventProperties() {
    final featureFlags = _getFeatureFlags();

    final featureVariantProperties = <String, Object?>{};
    if (featureFlags != null) {
      for (final entry in featureFlags.entries) {
        featureVariantProperties['\$feature/${entry.key}'] = entry.value;
      }
    }

    return {
      ...maybeAdd(r'$active_feature_flags', featureFlags?.keys.toList()),
      ...featureVariantProperties,
      ...super.getCommonEventProperties(),
    };
  }

  /// Platform context (OS, app, device) attached to every event. Merged with
  /// the lowest precedence so registered super properties and event-level
  /// properties can override it, matching the native PostHog SDKs.
  ///
  /// Returns nothing by default; platform implementations override this.
  @protected
  Map<String, Object?> getContextProperties() => {};

  /// Default person properties sent with every feature flag evaluation
  /// request, unless disabled via `setDefaultPersonProperties`. Explicitly
  /// set person properties override them.
  ///
  /// Returns nothing by default; platform implementations override this.
  @protected
  Map<String, Object?> getDefaultPersonPropertiesForFlags() => {};

  Map<String, Object?> _enrichProperties(Map<String, Object?>? properties) {
    return {
      ...getContextProperties(),
      ...props,
      ...(properties ?? {}),
      ...getCommonEventProperties(),
      r'$session_id': getSessionId(),
    };
  }

  /// Returns the current session ID.
  String getSessionId() {
    var sessionId =
        getPersistedProperty<String>(PostHogPersistedProperty.sessionId);
    final sessionLastTimestamp = getPersistedProperty<int>(
            PostHogPersistedProperty.sessionLastTimestamp) ??
        0;
    final sessionStartTimestamp = getPersistedProperty<int>(
            PostHogPersistedProperty.sessionStartTimestamp) ??
        0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessionLastDif = now - sessionLastTimestamp;
    final sessionStartDif = now - sessionStartTimestamp;

    if (sessionId == null ||
        sessionLastDif > _sessionExpiration.inMilliseconds ||
        sessionStartDif > _sessionMaxLength.inMilliseconds) {
      sessionId = generateUuidV7();
      setPersistedProperty(PostHogPersistedProperty.sessionId, sessionId);
      setPersistedProperty(PostHogPersistedProperty.sessionStartTimestamp, now);
    }
    setPersistedProperty(PostHogPersistedProperty.sessionLastTimestamp, now);

    return sessionId;
  }

  /// Resets the session ID.
  void resetSessionId() {
    wrap(() {
      setPersistedProperty(PostHogPersistedProperty.sessionId, null);
      setPersistedProperty(PostHogPersistedProperty.sessionLastTimestamp, null);
      setPersistedProperty(
          PostHogPersistedProperty.sessionStartTimestamp, null);
    });
  }

  /// Returns the current anonymous ID.
  String getAnonymousId() {
    var anonId =
        getPersistedProperty<String>(PostHogPersistedProperty.anonymousId);
    if (anonId == null) {
      anonId = generateUuidV7();
      setPersistedProperty(PostHogPersistedProperty.anonymousId, anonId);
    }
    return anonId;
  }

  /// Returns the current distinct ID.
  String getDistinctId() {
    return getPersistedProperty<String>(PostHogPersistedProperty.distinctId) ??
        getAnonymousId();
  }

  /// Identifies a user with a distinct ID and optional properties.
  void identify(String? distinctId,
      {Map<String, Object?>? properties, PostHogCaptureOptions? options}) {
    wrap(() {
      if (!_requirePersonProcessing('posthog.identify')) return;

      final previousDistinctId = getDistinctId();
      final newDistinctId = distinctId ?? previousDistinctId;

      // $set/$set_once are lifted out of a copy so the caller's map (which
      // may be const) is never modified.
      final remaining = properties == null ? null : {...properties};
      if (remaining != null) {
        _setGroupsFromProperties(remaining);
      }

      // Null values stay: `$set: {prop: null}` is an explicit unset.
      final userPropsOnce =
          _asNullablePropertyMap(remaining?.remove(r'$set_once'));
      final userProps =
          _asNullablePropertyMap(remaining?.remove(r'$set')) ?? remaining;

      final allProperties = _enrichProperties({
        r'$anon_distinct_id': getAnonymousId(),
        ...maybeAdd(r'$set', userProps),
        ...maybeAdd(r'$set_once', userPropsOnce),
      });

      if (newDistinctId != previousDistinctId) {
        setPersistedProperty(
            PostHogPersistedProperty.anonymousId, previousDistinctId);
        setPersistedProperty(
            PostHogPersistedProperty.distinctId, newDistinctId);
        setPersistedProperty(PostHogPersistedProperty.personMode, 'identified');
        _setPersonPropertiesForFlagsIfNeeded(userProps, userPropsOnce);
        reloadFeatureFlags();

        identifyStateless(newDistinctId,
            properties: allProperties, options: options);

        _cachedPersonProperties = getPersonPropertiesHash(
          newDistinctId,
          userProps,
          userPropsOnce,
        );
      } else if (userProps != null || userPropsOnce != null) {
        setPersonProperties(
          userPropertiesToSet: userProps,
          userPropertiesToSetOnce: userPropsOnce,
        );
      }
    });
  }

  /// Captures an event.
  void capture(String event,
      {Map<String, Object?>? properties, PostHogCaptureOptions? options}) {
    wrap(() {
      final distinctId = getDistinctId();

      if (properties != null) {
        _setGroupsFromProperties(properties);
        _setPersonPropertiesForFlagsIfNeeded(
          _asPropertyMap(properties[r'$set']),
          _asPropertyMap(properties[r'$set_once']),
        );
      }

      final allProperties = _enrichProperties(properties);

      final hasPersonProcessing = _hasPersonProcessing();
      allProperties[r'$process_person_profile'] = hasPersonProcessing;
      allProperties[r'$is_identified'] = _isIdentified();

      if (hasPersonProcessing) {
        _requirePersonProcessing('capture');
      }

      captureStateless(distinctId, event,
          properties: allProperties, options: options);
    });
  }

  /// Creates an alias for a user.
  void alias(String alias) {
    wrap(() {
      if (!_requirePersonProcessing('posthog.alias')) return;

      final distinctId = getDistinctId();
      final allProperties = _enrichProperties({});
      aliasStateless(alias, distinctId, properties: allProperties);
    });
  }

  /// Applies the `$groups` entry of an event property map, tolerating the
  /// loose runtime types of user-supplied and JSON-decoded maps.
  void _setGroupsFromProperties(Map<String, Object?> properties) {
    final groups = properties[r'$groups'];
    if (groups == null) return;
    if (groups is! Map) {
      logger.warn(r'Ignoring $groups: expected a map, got', groups);
      return;
    }
    final groupProps = <String, Object>{
      for (final entry in groups.entries)
        if (entry.value != null) '${entry.key}': entry.value as Object,
    };
    if (groupProps.isNotEmpty) {
      _setGroups(groupProps);
    }
  }

  /// Sets group memberships for the current user.
  void _setGroups(Map<String, Object> groupProps) {
    if (!_requirePersonProcessing('posthog.group')) return;

    final existingGroups = (props[r'$groups'] as Map<String, Object?>?) ?? {};

    register({
      r'$groups': {...existingGroups, ...groupProps},
    });

    if (groupProps.keys
        .any((type) => existingGroups[type] != groupProps[type])) {
      reloadFeatureFlags();
    }
  }

  /// Associates the current user with a group and optionally sets group properties.
  /// If [groupProperties] is provided, a `$groupidentify` event is sent.
  void group(
    String groupType,
    Object groupKey, {
    Map<String, Object?>? groupProperties,
    PostHogCaptureOptions? options,
  }) {
    wrap(() {
      _setGroups({groupType: groupKey});

      if (groupProperties != null) {
        if (!_requirePersonProcessing('posthog.group')) return;

        final distinctId = getDistinctId();
        final eventProperties = _enrichProperties({});
        groupIdentifyStateless(
          groupType,
          groupKey,
          groupProperties: groupProperties,
          options: options,
          distinctId: distinctId,
          eventProperties: eventProperties,
        );
      }
    });
  }

  /// Person properties passed to identify() and capture() also feed flag
  /// evaluation, matching the mobile SDKs. $set wins over $set_once for the
  /// same key.
  void _setPersonPropertiesForFlagsIfNeeded(
    Map<String, Object?>? userProperties,
    Map<String, Object?>? userPropertiesSetOnce,
  ) {
    final merged = <String, Object?>{
      ...?userPropertiesSetOnce,
      ...?userProperties,
    };
    if (merged.isEmpty) return;
    setPersonPropertiesForFlags(merged, reloadFlags: false);
  }

  /// Sets person properties for feature flag evaluation.
  void setPersonPropertiesForFlags(Map<String, Object?> properties,
      {bool reloadFlags = true}) {
    wrap(() {
      final existing = getPersistedProperty<Map<String, Object?>>(
              PostHogPersistedProperty.personProperties) ??
          {};
      setPersistedProperty(
        PostHogPersistedProperty.personProperties,
        {...existing, ...properties},
      );
      if (reloadFlags) reloadFeatureFlags();
    });
  }

  /// Resets person properties for feature flag evaluation.
  void resetPersonPropertiesForFlags() {
    wrap(() {
      setPersistedProperty(PostHogPersistedProperty.personProperties, null);
    });
  }

  /// Sets group properties for feature flag evaluation. The /flags API
  /// accepts arbitrary JSON property values, so values are not forced to
  /// strings.
  void setGroupPropertiesForFlags(
      Map<String, Map<String, Object?>> properties) {
    wrap(() {
      final existing = getPersistedProperty<Map<String, Object?>>(
              PostHogPersistedProperty.groupProperties) ??
          {};

      final merged = <String, Object?>{...existing};
      for (final entry in properties.entries) {
        final current = merged[entry.key];
        merged[entry.key] = {
          if (current is Map)
            for (final e in current.entries) '${e.key}': e.value,
          ...entry.value,
        };
      }

      setPersistedProperty(PostHogPersistedProperty.groupProperties, merged);
    });
  }

  /// Resets group properties for feature flag evaluation.
  void resetGroupPropertiesForFlags() {
    wrap(() {
      setPersistedProperty(PostHogPersistedProperty.groupProperties, null);
    });
  }

  Future<PostHogFlagsResponse?> _flagsAsync(
      {bool sendAnonDistinctId = true}) async {
    final inFlight = _flagsResponseFuture;
    if (inFlight != null) {
      logger.info('Feature flags are being loaded already, queuing reload.');
      final displaced = _pendingFlagsRequest;
      if (displaced != null) {
        inFlight
            .then(displaced.completer.complete)
            .catchError(displaced.completer.completeError);
      }

      final completer = Completer<PostHogFlagsResponse?>();
      _pendingFlagsRequest = (
        completer: completer,
        sendAnonDistinctId: sendAnonDistinctId,
      );
      return completer.future;
    }

    return _doFlagsAsync(sendAnonDistinctId: sendAnonDistinctId);
  }

  Future<PostHogFlagsResponse?> _doFlagsAsync(
      {required bool sendAnonDistinctId}) async {
    final completer = Completer<PostHogFlagsResponse?>();
    // The shared future usually has no listener; without ignore() its
    // completeError would surface as an unhandled async error.
    _flagsResponseFuture = completer.future..ignore();

    try {
      final distinctId = getDistinctId();
      final groupsMap = (props[r'$groups'] as Map<String, Object?>?) ?? {};
      final personProperties = <String, Object?>{
        if (_setDefaultPersonProperties)
          ...getDefaultPersonPropertiesForFlags(),
        ...getPersistedProperty<Map<String, Object?>>(
                PostHogPersistedProperty.personProperties) ??
            {},
      };
      final groupProperties = getPersistedProperty<Map<String, Object?>>(
              PostHogPersistedProperty.groupProperties) ??
          {};

      final extraProperties = <String, Object?>{
        if (sendAnonDistinctId) r'$anon_distinct_id': getAnonymousId(),
      };

      final result = await getFlags(
        distinctId,
        groups: groupsMap.cast<String, Object>(),
        personProperties: personProperties,
        groupProperties: groupProperties.map((k, v) => MapEntry(
            k, v is Map ? Map<String, Object?>.from(v) : <String, Object?>{})),
        extraPayload: extraProperties,
      );

      if (result is GetFlagsFailure) {
        _setKnownFeatureFlagDetails(PostHogFlagsStorageFormat(
          flags: _getStoredFlagDetails()?.flags ?? {},
          requestError: result.error,
        ));
        completer.complete(null);
        return null;
      }

      final res = (result as GetFlagsSuccess).response;

      if (res.quotaLimited?.contains(QuotaLimitedFeature.featureFlags) ==
          true) {
        // Unlike posthog-js-lite, cached flags are kept and keep serving
        // (matches the mobile SDKs), so the returned state must be the
        // cached one - not the empty quota response.
        final stored = _getStoredFlagDetails();
        final kept = PostHogFlagsStorageFormat(
          flags: stored?.flags ?? {},
          requestId: stored?.requestId,
          evaluatedAt: stored?.evaluatedAt,
          errorsWhileComputingFlags: stored?.errorsWhileComputingFlags,
          quotaLimited: res.quotaLimited,
        );
        _setKnownFeatureFlagDetails(kept);
        logger.warn('[FEATURE FLAGS] Feature flags quota limit exceeded.');
        final cached = kept.toResponse();
        completer.complete(cached);
        return cached;
      }

      if (_sendFeatureFlagEvents) {
        _flagCallReported.clear();
      }

      var resolvedFlags = res.flags;
      if (res.errorsWhileComputingFlags) {
        final currentDetails = _getStoredFlagDetails();
        logger.info(
            'Cached feature flags: ', jsonEncode(currentDetails?.flags));

        final filteredFlags = <String, PostHogFeatureFlagDetail>{};
        for (final entry in res.flags.entries) {
          if (entry.value.failed != true) {
            filteredFlags[entry.key] = entry.value;
          }
        }

        resolvedFlags = {
          ...(currentDetails?.flags ?? {}),
          ...filteredFlags,
        };
      }

      // An empty response is stored too: it clears stale flags and any
      // previously recorded request error.
      _setKnownFeatureFlagDetails(PostHogFlagsStorageFormat(
        flags: resolvedFlags,
        requestId: res.requestId,
        evaluatedAt: res.evaluatedAt,
        errorsWhileComputingFlags: res.errorsWhileComputingFlags,
        quotaLimited: res.quotaLimited,
      ));

      completer.complete(res);
      return res;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _flagsResponseFuture = null;

      final pending = _pendingFlagsRequest;
      if (pending != null) {
        _pendingFlagsRequest = null;
        logger.info('Executing pending feature flags reload.');
        _flagsAsync(sendAnonDistinctId: pending.sendAnonDistinctId)
            .then(pending.completer.complete)
            .catchError(pending.completer.completeError);
      }
    }
  }

  void _setKnownFeatureFlagDetails(PostHogFlagsStorageFormat? details) {
    wrap(() {
      setPersistedProperty(
          PostHogPersistedProperty.featureFlagDetails, details?.toJson());

      final flagValues = details != null
          ? PostHogFlagsResponse(flags: details.flags).featureFlags
          : <String, PostHogFeatureFlagValue>{};
      events.emit('featureflags', flagValues);
    });
  }

  // A persisted record of an unexpected shape must not turn every capture()
  // into a throw - the corrupted key is dropped instead.
  T? _discardingMalformed<T>(
      PostHogPersistedProperty key, T? Function() parse) {
    try {
      return parse();
    } catch (e) {
      logger.error('Discarding malformed persisted value for ${key.key}:', e);
      setPersistedProperty(key, null);
      return null;
    }
  }

  PostHogFlagsStorageFormat? _getStoredFlagDetails() {
    return _discardingMalformed(PostHogPersistedProperty.featureFlagDetails,
        () {
      final raw = getPersistedProperty<Map<String, Object?>>(
          PostHogPersistedProperty.featureFlagDetails);
      if (raw == null) return null;
      return PostHogFlagsStorageFormat.fromJson(raw,
          onMalformedFlag: (key, e) =>
              logger.warn('Skipping malformed feature flag "$key":', e));
    });
  }

  /// Gets the result for a specific feature flag.
  PostHogFeatureFlagResult? getFeatureFlagResult(String key,
      {PostHogFeatureFlagResultOptions? options}) {
    return _getFeatureFlagResult(key, sendEvent: options?.sendEvent);
  }

  PostHogFeatureFlagResult? _getFeatureFlagResult(
    String key, {
    bool? sendEvent,
  }) {
    final storedDetails = _getStoredFlagDetails();
    final details = storedDetails?.toResponse();
    final isQuotaLimited = storedDetails?.quotaLimited
            ?.contains(QuotaLimitedFeature.featureFlags) ==
        true;
    final featureFlag = details?.flags[key];
    final shouldSendEvent = (sendEvent ?? _sendFeatureFlagEvents) &&
        !(_flagCallReported[key] ?? false);
    final flagValue = getFeatureFlagValue(featureFlag);

    if (shouldSendEvent) {
      final errors = <String>[];
      if (storedDetails?.requestError != null) {
        final reqError = storedDetails!.requestError!;
        switch (reqError.type) {
          case FeatureFlagRequestErrorType.timeout:
            errors.add(FeatureFlagErrorType.timeout.value);
          case FeatureFlagRequestErrorType.apiError:
            if (reqError.statusCode != null) {
              errors.add(FeatureFlagErrorType.apiError(reqError.statusCode!));
            }
          case FeatureFlagRequestErrorType.connectionError:
            errors.add(FeatureFlagErrorType.connectionError.value);
          case FeatureFlagRequestErrorType.unknownError:
            errors.add(FeatureFlagErrorType.unknownError.value);
        }
      } else if (storedDetails != null) {
        if (storedDetails.errorsWhileComputingFlags == true) {
          errors.add(FeatureFlagErrorType.errorsWhileComputing.value);
        }
        // A value answered from the cache is a valid answer: the quota state
        // is only an error when there is nothing to serve.
        if (flagValue == null) {
          if (isQuotaLimited) {
            errors.add(FeatureFlagErrorType.quotaLimited.value);
          } else if (featureFlag == null) {
            errors.add(FeatureFlagErrorType.flagMissing.value);
          }
        }
      }

      final featureFlagError = errors.isNotEmpty ? errors.join(',') : null;

      _flagCallReported[key] = true;

      final captureProperties = <String, Object?>{
        r'$feature_flag': key,
        r'$feature_flag_response': flagValue,
        ...maybeAdd(r'$feature_flag_id', featureFlag?.metadata?.id),
        ...maybeAdd(r'$feature_flag_version', featureFlag?.metadata?.version),
        ...maybeAdd(r'$feature_flag_reason',
            featureFlag?.reason?.description ?? featureFlag?.reason?.code),
        ...maybeAdd(r'$feature_flag_request_id', details?.requestId),
        ...maybeAdd(r'$feature_flag_evaluated_at', details?.evaluatedAt),
        ...maybeAdd(r'$feature_flag_error', featureFlagError),
      };

      capture(r'$feature_flag_called', properties: captureProperties);
    }

    if (flagValue == null) return null;

    // Payloads only accompany enabled flags, matching featureFlagPayloads
    // and posthog-js-lite.
    final rawPayload =
        featureFlag?.enabled == true ? featureFlag?.metadata?.payload : null;
    final payload = rawPayload != null ? parsePayload(rawPayload) : null;
    return PostHogFeatureFlagResult(
      key: key,
      enabled: flagValue is String ? true : flagValue as bool,
      variant: flagValue is String ? flagValue : null,
      payload: payload,
    );
  }

  /// Gets a feature flag value.
  ///
  /// Returns null if the flag does not exist or has not been loaded.
  PostHogFeatureFlagValue? getFeatureFlag(String key) {
    final result = _getFeatureFlagResult(key);
    if (result == null) return null;
    return result.variant ?? result.enabled;
  }

  Map<String, PostHogFeatureFlagValue>? _getFeatureFlags() {
    return getFeatureFlagDetails()?.featureFlags;
  }

  /// Gets full feature flag details.
  PostHogFlagsResponse? getFeatureFlagDetails() {
    return _getStoredFlagDetails()?.toResponse();
  }

  /// Checks if a feature flag is enabled.
  bool? isFeatureEnabled(String key) {
    final response = getFeatureFlag(key);
    if (response == null) return null;
    if (response is bool) return response;
    return true; // String variants are truthy
  }

  /// Triggers a feature flags reload (fire and forget).
  void reloadFeatureFlags(
      {void Function(
              Object? error, Map<String, PostHogFeatureFlagValue>? flags)?
          callback}) {
    _flagsAsync().then((res) {
      callback?.call(null, res?.featureFlags);
    }).catchError((Object e) {
      callback?.call(e, null);
      if (callback == null) {
        logger.info('Error reloading feature flags', e);
      }
    });
  }

  /// Reloads feature flags and returns the result.
  Future<Map<String, PostHogFeatureFlagValue>?> reloadFeatureFlagsAsync(
      {bool sendAnonDistinctId = true}) async {
    final res = await _flagsAsync(sendAnonDistinctId: sendAnonDistinctId);
    return res?.featureFlags;
  }

  /// Registers a callback for feature flag changes.
  void Function() onFeatureFlags(
      void Function(Map<String, PostHogFeatureFlagValue> flags) callback) {
    return on('featureflags', (Object? _) {
      final flags = _getFeatureFlags();
      if (flags != null) {
        callback(flags);
      }
    });
  }

  /// Registers a callback for a specific feature flag.
  void Function() onFeatureFlag(
      String key, void Function(PostHogFeatureFlagValue value) callback) {
    return on('featureflags', (Object? _) {
      final flagResponse = getFeatureFlag(key);
      if (flagResponse != null) {
        callback(flagResponse);
      }
    });
  }

  bool _isIdentified() {
    final personMode =
        getPersistedProperty<String>(PostHogPersistedProperty.personMode);

    if (personMode == 'identified') return true;

    if (personMode == null) {
      final distinctId =
          getPersistedProperty<String>(PostHogPersistedProperty.distinctId);
      final anonymousId =
          getPersistedProperty<String>(PostHogPersistedProperty.anonymousId);
      if (distinctId != null &&
          anonymousId != null &&
          distinctId != anonymousId) {
        return true;
      }
    }
    return false;
  }

  Map<String, Object?> _getGroups() {
    return (props[r'$groups'] as Map<String, Object?>?) ?? {};
  }

  bool _hasPersonProcessing() {
    if (_personProfiles == PostHogPersonProfiles.always) return true;
    if (_personProfiles == PostHogPersonProfiles.never) return false;

    final isIdentified = _isIdentified();
    final hasGroups = _getGroups().isNotEmpty;
    final personProcessingEnabled = getPersistedProperty<bool>(
            PostHogPersistedProperty.enablePersonProcessing) ==
        true;

    return isIdentified || hasGroups || personProcessingEnabled;
  }

  bool _requirePersonProcessing(String functionName) {
    if (_personProfiles == PostHogPersonProfiles.never) {
      logger.error(
          '$functionName was called, but personProfiles is set to "never". This call will be ignored.');
      return false;
    }

    setPersistedProperty(PostHogPersistedProperty.enablePersonProcessing, true);
    return true;
  }

  /// Creates a person profile for the current user.
  void createPersonProfile() {
    if (_hasPersonProcessing()) return;
    if (!_requirePersonProcessing('posthog.createPersonProfile')) return;
    capture(r'$set', properties: {r'$set': {}, r'$set_once': {}});
  }

  /// Sets properties on the person profile.
  void setPersonProperties({
    Map<String, Object?>? userPropertiesToSet,
    Map<String, Object?>? userPropertiesToSetOnce,
    bool reloadFlags = true,
  }) {
    wrap(() {
      final isSetEmpty =
          userPropertiesToSet == null || userPropertiesToSet.isEmpty;
      final isSetOnceEmpty =
          userPropertiesToSetOnce == null || userPropertiesToSetOnce.isEmpty;
      if (isSetEmpty && isSetOnceEmpty) return;

      if (!_requirePersonProcessing('posthog.setPersonProperties')) return;

      final hash = getPersonPropertiesHash(
          getDistinctId(), userPropertiesToSet, userPropertiesToSetOnce);

      if (_cachedPersonProperties == hash) {
        logger.info(
            'A duplicate setPersonProperties call was made. It has been ignored.');
        return;
      }

      final mergedProperties = {
        ...(userPropertiesToSetOnce ?? {}),
        ...(userPropertiesToSet ?? {}),
      };
      setPersonPropertiesForFlags(mergedProperties, reloadFlags: reloadFlags);

      capture(r'$set', properties: {
        r'$set': userPropertiesToSet ?? {},
        r'$set_once': userPropertiesToSetOnce ?? {},
      });

      _cachedPersonProperties = hash;
    });
  }

  /// Override processBeforeEnqueue to run before_send hooks.
  @override
  FutureOr<Map<String, Object?>?> processBeforeEnqueue(
      Map<String, Object?> message) {
    if (_beforeSend == null || _beforeSend.isEmpty) return message;

    final props = (message['properties'] as Map<String, Object?>?) ?? {};
    final timestamp = message['timestamp'];
    // Internal messages carry null values and loosely typed $set maps, so
    // the event copy is built defensively instead of with throwing casts.
    final event = PostHogEvent(
      uuid: message['uuid'] as String,
      event: message['event'] as String,
      properties: _nonNullProperties(props),
      userProperties: _asPropertyMap(props[r'$set']),
      userPropertiesSetOnce: _asPropertyMap(props[r'$set_once']),
      timestamp: timestamp is String ? DateTime.parse(timestamp) : null,
    );

    final beforeSendResult = _runBeforeSend(event);
    if (beforeSendResult is Future<PostHogEvent?>) {
      return beforeSendResult
          .then((result) => _applyBeforeSendResult(result, message, props));
    }
    return _applyBeforeSendResult(beforeSendResult, message, props);
  }

  Map<String, Object?>? _applyBeforeSendResult(PostHogEvent? result,
      Map<String, Object?> message, Map<String, Object?> props) {
    if (result == null) return null;

    // Null-valued properties (e.g. $feature_flag_response: null) cannot be
    // represented in PostHogEvent, so callbacks never see them; they pass
    // through unless the callback dropped the whole property map.
    final resultProps = <String, Object?>{
      if (result.properties != null)
        for (final entry in props.entries)
          if (entry.value == null) entry.key: null,
      ...?result.properties,
    };
    if (result.userProperties != null) {
      resultProps[r'$set'] = result.userProperties;
    } else {
      resultProps.remove(r'$set');
    }
    if (result.userPropertiesSetOnce != null) {
      resultProps[r'$set_once'] = result.userPropertiesSetOnce;
    } else {
      resultProps.remove(r'$set_once');
    }

    return {
      ...message,
      'uuid': result.uuid,
      'event': result.event,
      'properties': resultProps,
      'timestamp': result.timestamp.toUtc().toIso8601String(),
    };
  }

  FutureOr<PostHogEvent?> _runBeforeSend(PostHogEvent event) {
    final callbacks = _beforeSend;
    if (callbacks == null) return event;

    PostHogEvent? result = event;
    for (var i = 0; i < callbacks.length; i++) {
      try {
        final fnResult = callbacks[i](result!);
        if (fnResult is Future<PostHogEvent?>) {
          // Continue from this point: re-running the list would double the
          // earlier callbacks' side effects.
          return _continueBeforeSendAsync(fnResult, result, i + 1, event.event);
        }
        result = fnResult;
      } catch (e) {
        logger.error(
            "Error in beforeSend callback for event '${event.event}':", e);
      }
      if (result == null) {
        logger
            .info("Event '${event.event}' was rejected in beforeSend callback");
        return null;
      }
    }
    return result;
  }

  Future<PostHogEvent?> _continueBeforeSendAsync(
    Future<PostHogEvent?> pending,
    PostHogEvent fallback,
    int nextIndex,
    String eventName,
  ) async {
    final callbacks = _beforeSend!;
    PostHogEvent? result;
    try {
      result = await pending;
    } catch (e) {
      logger.error("Error in beforeSend callback for event '$eventName':", e);
      result = fallback;
    }
    if (result == null) {
      logger.info("Event '$eventName' was rejected in beforeSend callback");
      return null;
    }
    for (var i = nextIndex; i < callbacks.length; i++) {
      try {
        final fnResult = callbacks[i](result!);
        result = fnResult is Future<PostHogEvent?> ? await fnResult : fnResult;
      } catch (e) {
        logger.error("Error in beforeSend callback for event '$eventName':", e);
      }
      if (result == null) {
        logger.info("Event '$eventName' was rejected in beforeSend callback");
        return null;
      }
    }
    return result;
  }

  static Map<String, Object> _nonNullProperties(Map<String, Object?> map) {
    return {
      for (final entry in map.entries)
        if (entry.value != null) entry.key: entry.value as Object,
    };
  }

  static Map<String, Object>? _asPropertyMap(Object? value) {
    if (value is! Map) return null;
    return {
      for (final entry in value.entries)
        if (entry.value != null) entry.key.toString(): entry.value as Object,
    };
  }

  static Map<String, Object?>? _asNullablePropertyMap(Object? value) {
    if (value is! Map) return null;
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
}

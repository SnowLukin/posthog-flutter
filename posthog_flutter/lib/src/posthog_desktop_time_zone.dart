import 'dart:io';

/// The IANA name of the local time zone, such as `Europe/Berlin`.
///
/// Only available on Linux: Windows names its zones differently ("W. Europe
/// Standard Time"), and translating them takes a mapping table.
class DesktopTimeZone {
  /// Reads the zone from `TZ` in [environment], or else from the target of
  /// `/etc/localtime`. Null on Windows and when neither names a zone.
  static String? read(Map<String, String> environment) {
    if (Platform.isWindows) return null;
    final fromVariable = fromTzVariable(environment['TZ']);
    if (fromVariable != null) return fromVariable;
    try {
      return fromZoneInfoPath(
        File('/etc/localtime').resolveSymbolicLinksSync(),
      );
    } on FileSystemException {
      return null;
    }
  }

  /// The zone a `TZ` value names: a zone name, optionally after a `:`, or
  /// the path of a file in a zoneinfo directory.
  ///
  /// Null for a POSIX rule such as `CET-1CEST,M3.5.0,M10.5.0/3`, which names
  /// no zone.
  static String? fromTzVariable(String? value) {
    if (value == null) return null;
    final tz = value.startsWith(':') ? value.substring(1) : value;
    return tz.startsWith('/') ? fromZoneInfoPath(tz) : _zoneName(tz);
  }

  /// The zone of a file in a zoneinfo directory, such as
  /// `/usr/share/zoneinfo/Europe/Berlin`.
  static String? fromZoneInfoPath(String path) {
    const directory = '/zoneinfo/';
    final index = path.indexOf(directory);
    if (index < 0) return null;
    return _zoneName(path.substring(index + directory.length));
  }

  static String? _zoneName(String value) {
    // Copies of the database that differ in leap seconds, not in zone names.
    final zone = value.replaceFirst(RegExp('^(posix|right)/'), '');
    return _zoneNamePattern.hasMatch(zone) ? zone : null;
  }

  /// Zone names use no digits, which would make them read as POSIX rules,
  /// except for the fixed offsets (`Etc/GMT+10`) and four legacy zones.
  static final _zoneNamePattern = RegExp(
    r'^([A-Za-z][A-Za-z._+-]*(/[A-Za-z._+-]+)*|(Etc/)?GMT[+-]?\d{1,2}|'
    r'EST5EDT|CST6CDT|MST7MDT|PST8PDT)$',
  );
}

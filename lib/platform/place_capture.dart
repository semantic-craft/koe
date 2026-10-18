import 'dart:async';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../state/recording_library.dart';

/// Best-effort capture of a coarse place for a phone recording.
///
/// Implementations must never block or fail a recording. A denied permission,
/// disabled service, timeout, or empty reverse-geocode result returns null and
/// leaves the recording's place blank.
abstract class PlaceCapture {
  Future<RecordingPlace?> capture();
}

class DevicePlaceCapture implements PlaceCapture {
  const DevicePlaceCapture();

  static const _timeout = Duration(seconds: 10);

  @override
  Future<RecordingPlace?> capture() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: _timeout,
        ),
      ).timeout(_timeout);
      final marks = await Geocoding()
          .placemarkFromCoordinates(position.latitude, position.longitude)
          .timeout(_timeout);
      if (marks.isEmpty) return null;
      final label = coarsePlaceLabel(marks.first);
      if (label.isEmpty) return null;
      return RecordingPlace(
        label: label,
        source: RecordingPlaceSource.automatic,
        capturedAt: DateTime.now(),
      );
    } catch (_) {
      // Location is optional: never surface a failure into the recording flow.
      return null;
    }
  }
}

/// Drops street-level detail so only a region label leaves the device.
String coarsePlaceLabel(Placemark mark) {
  final parts = <String>[
    ?_clean(mark.administrativeArea),
    ?_clean(mark.locality),
    ?_clean(mark.subLocality),
  ];
  final unique = <String>[];
  for (final part in parts) {
    if (!unique.contains(part)) unique.add(part);
  }
  // Prefer city + district; keep the province only when nothing finer exists.
  if (unique.length > 2) return unique.sublist(unique.length - 2).join(' ');
  return unique.join(' ');
}

String? _clean(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

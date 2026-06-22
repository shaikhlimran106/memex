import 'package:memex/agent/prompts.dart';
import 'package:memex/data/services/file_system_service.dart';
import 'package:memex/data/services/geocoding_service.dart';
import 'package:memex/utils/exif_utils.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';

final _logger = getLogger('ImageExifContext');

/// Build a human-readable EXIF metadata block (capture time, GPS, and the
/// reverse-geocoded address) for the image at [imagePath]. Returns null when
/// the image carries no usable timestamp/GPS.
///
/// This is the single source of truth for the capture-context block so the
/// user-facing chat path ([ChatService]) and the subagent delegation path
/// (which re-derives it from the `fs://` reference in a task brief, since the
/// child can't see the image) produce identical reminders. It lives in this
/// neutral file — depending only on EXIF/geocode/storage utilities — to avoid
/// the import cycle that would arise if the delegation tool reached back into
/// ChatService.
Future<String?> buildImageExifInfo(String userId, String imagePath) async {
  try {
    final exif = await ExifUtils.extractExifData(imagePath);
    if (exif.isEmpty) return null;

    final infoLines = <String>[];

    if (exif.containsKey('datetime_original_str')) {
      infoLines.add('${Prompts.captureTime}: ${exif['datetime_original_str']}');
    }

    if (exif.containsKey('gps_coordinates')) {
      try {
        final coords = exif['gps_coordinates'] as List;
        final lat = coords[0] as double;
        final lng = coords[1] as double;
        infoLines.add(
          '${Prompts.gpsCoordinates}: ${lat.toStringAsFixed(6)}, '
          '${lng.toStringAsFixed(6)}',
        );

        final geocoded =
            await GeocodingService.instance.reverseGeocode(lat, lng);
        if (geocoded != null) {
          final locationConfig = await UserStorage.getLocationContextConfig();
          final address = geocoded.fullAddress ??
              geocoded.summary(locationConfig.granularity);
          if (address.isNotEmpty) {
            var addressLine = '${Prompts.captureLocation}: $address';
            final markAddress = await FileSystemService.instance
                .getNearestUserLocation(userId, lat, lng);
            if (markAddress != null) {
              addressLine +=
                  ', very close to user marked location ($markAddress) (less than 50 meters)';
            }
            infoLines.add(addressLine);
          }
        }
      } catch (e) {
        _logger.warning('Reverse geocode failed for image: $e');
      }
    }

    if (infoLines.isEmpty) return null;
    return '${Prompts.imageMetadata}:\n${infoLines.join('\n')}';
  } catch (e) {
    _logger.warning('Failed to extract EXIF for image $imagePath: $e');
    return null;
  }
}

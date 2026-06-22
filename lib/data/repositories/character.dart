import 'package:memex/domain/models/character_model.dart';
import 'package:memex/data/services/character_service.dart';
import 'package:memex/utils/logger.dart';
import 'package:memex/utils/user_storage.dart';
import 'package:memex/data/services/api_exception.dart';

final _logger = getLogger('CharacterEndpoint');
final _characterService = CharacterService.instance;

/// Get all characters
///
/// Returns:
///   List<CharacterModel>: character list
Future<List<CharacterModel>> getCharacters() async {
  _logger.info('getCharacters called');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw ApiException('User not logged in, cannot get character list');
    }

    final characters = await _characterService.getAllCharacters(userId);
    return characters;
  } catch (e) {
    _logger.severe('Failed to get characters: $e');
    rethrow;
  }
}

/// Get character by ID
///
/// Args:
///   characterId: character ID
///
/// Returns:
///   CharacterModel: character detail
///
/// Throws:
///   ApiException: if character not found
Future<CharacterModel> getCharacter(String characterId) async {
  _logger.info('getCharacter called: characterId=$characterId');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw ApiException('User not logged in, cannot get character detail');
    }

    if (characterId.isEmpty) {
      throw ApiException('Character ID cannot be empty');
    }

    final character = await _characterService.getCharacter(userId, characterId);
    if (character == null) {
      throw ApiException('Character not found: $characterId');
    }

    return character;
  } catch (e) {
    _logger.severe('Failed to get character $characterId: $e');
    rethrow;
  }
}

/// Create a new character
///
/// Args:
///   name: character name
///   tags: tag list
///   persona: full persona text
///
/// Returns:
///   CharacterModel: created character
///
/// Throws:
///   ApiException: if params invalid
Future<CharacterModel> createCharacterEndpoint({
  required String name,
  required List<String> tags,
  required String persona,
}) async {
  _logger.info('createCharacter called: name=$name');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw ApiException('User not logged in, cannot create character');
    }

    if (name.trim().isEmpty) {
      throw ApiException('Character name cannot be empty');
    }
    if (persona.trim().isEmpty) {
      throw ApiException('Character persona cannot be empty');
    }

    final characterData = {
      'name': name.trim(),
      'tags': tags,
      'persona': persona.trim(),
      'enabled': true,
    };

    final character = await _characterService.createCharacter(
      userId: userId,
      characterData: characterData,
    );

    return character;
  } catch (e) {
    _logger.severe('Failed to create character: $e');
    rethrow;
  }
}

/// Update character
///
/// Args:
///   characterId: character ID
///   name: character name (optional)
///   tags: tag list (optional)
///   persona: full persona text (optional)
///
/// Returns:
///   CharacterModel: updated character
///
/// Throws:
///   ApiException: if character not found or params invalid
Future<CharacterModel> updateCharacterEndpoint({
  required String characterId,
  String? name,
  List<String>? tags,
  String? persona,
}) async {
  _logger.info('updateCharacter called: characterId=$characterId');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw ApiException('User not logged in, cannot update character');
    }

    if (characterId.isEmpty) {
      throw ApiException('Character ID cannot be empty');
    }

    final updates = <String, dynamic>{};
    if (name != null) {
      updates['name'] = name.trim();
    }
    if (tags != null) {
      updates['tags'] = tags;
    }
    if (persona != null) {
      updates['persona'] = persona.trim();
    }

    if (updates.isEmpty) {
      throw ApiException('Update content cannot be empty');
    }

    final character = await _characterService.updateCharacter(
      userId: userId,
      characterId: characterId,
      updates: updates,
    );

    if (character == null) {
      throw ApiException('Character not found: $characterId');
    }

    return character;
  } catch (e) {
    _logger.severe('Failed to update character $characterId: $e');
    rethrow;
  }
}

/// Delete character (physical delete)
///
/// Args:
///   characterId: character ID
///
/// Returns:
///   bool: success
///
/// Throws:
///   ApiException: if character not found
///
/// Note:
///   Client uses physical delete; character file is removed
Future<bool> deleteCharacterEndpoint(String characterId) async {
  _logger.info('deleteCharacter called: characterId=$characterId');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw ApiException('User not logged in, cannot delete character');
    }

    if (characterId.isEmpty) {
      throw ApiException('Character ID cannot be empty');
    }

    final success =
        await _characterService.deleteCharacter(userId, characterId);
    if (!success) {
      throw ApiException('Character not found: $characterId');
    }

    return true;
  } catch (e) {
    _logger.severe('Failed to delete character $characterId: $e');
    rethrow;
  }
}

/// Set character enabled/disabled
///
/// Args:
///   characterId: character ID
///   enabled: whether enabled
///
/// Returns:
///   bool: success
///
/// Throws:
///   ApiException: if character not found
Future<bool> setCharacterEnabledEndpoint(
    String characterId, bool enabled) async {
  _logger.info(
      'setCharacterEnabled called: characterId=$characterId, enabled=$enabled');

  try {
    final userId = await UserStorage.getUserId();
    if (userId == null) {
      throw ApiException('User not logged in, cannot set character status');
    }

    if (characterId.isEmpty) {
      throw ApiException('Character ID cannot be empty');
    }

    final success = await _characterService.setCharacterEnabled(
        userId, characterId, enabled);
    if (!success) {
      throw ApiException('Character not found: $characterId');
    }

    return true;
  } catch (e) {
    _logger.severe('Failed to set character enabled $characterId: $e');
    rethrow;
  }
}

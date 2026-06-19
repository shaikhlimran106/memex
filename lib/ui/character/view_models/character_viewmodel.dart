import 'package:flutter/foundation.dart';

import 'package:memex/domain/models/character_model.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/utils/result.dart';

/// ViewModel for the Character config page. Holds character list and
/// delegates CRUD to [MemexRouter].
class CharacterViewModel extends ChangeNotifier {
  CharacterViewModel({required MemexRouter router}) : _router = router;

  final MemexRouter _router;

  List<CharacterModel> characters = [];
  bool isLoading = false;

  Future<void> loadCharacters() async {
    isLoading = true;
    notifyListeners();
    final result = await _router.fetchCharacters();
    result.when(
      onOk: (list) => characters = list,
      onError: (_, __) {},
    );
    isLoading = false;
    notifyListeners();
  }

  Future<void> setCharacterEnabled(
      CharacterModel character, bool enabled) async {
    final result = await _router.setCharacterEnabled(character.id, enabled);
    result.when(
      onOk: (_) {
        final index = characters.indexWhere((c) => c.id == character.id);
        if (index != -1) {
          characters[index] = character.copyWith(enabled: enabled);
          notifyListeners();
        }
      },
      onError: (_, __) {},
    );
  }

  Future<void> deleteCharacter(CharacterModel character) async {
    await _router.deleteCharacter(character.id);
    characters.removeWhere((c) => c.id == character.id);
    notifyListeners();
  }
}

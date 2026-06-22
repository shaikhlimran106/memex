enum ReprocessCardsScope {
  cardsOnly('cards_only'),
  cardsAndRelatedFollowUps('cards_and_related_follow_ups');

  const ReprocessCardsScope(this.payloadValue);

  final String payloadValue;

  bool get includeRelatedFollowUps => this == cardsAndRelatedFollowUps;

  static ReprocessCardsScope fromPayload(Object? value) {
    final normalized = value?.toString().trim();
    if (normalized == cardsAndRelatedFollowUps.payloadValue) {
      return cardsAndRelatedFollowUps;
    }
    return cardsOnly;
  }
}

class ReprocessCardsPayloadKeys {
  const ReprocessCardsPayloadKeys._();

  static const scope = 'scope';
}

enum ReprocessCardsDownstreamMode {
  cardOnly('card_only'),
  postCardRouter('post_card_router');

  const ReprocessCardsDownstreamMode(this.payloadValue);

  final String payloadValue;

  bool get rerunDownstream => this == postCardRouter;

  static ReprocessCardsDownstreamMode fromPayload(Object? value) {
    final normalized = value?.toString().trim();
    if (normalized == postCardRouter.payloadValue ||
        normalized == 'rerun_downstream') {
      return postCardRouter;
    }
    return cardOnly;
  }
}

class ReprocessCardsPayloadKeys {
  const ReprocessCardsPayloadKeys._();

  static const downstreamMode = 'downstream_mode';
}

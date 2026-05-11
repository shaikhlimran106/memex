class AgentDefinitions {
  static const String pkmAgent = 'pkm_agent';
  static const String cardAgent = 'card_agent';
  static const String profileAgent = 'profile_agent';
  static const String knowledgeInsightAgent = 'knowledge_insight_agent';
  static const String scheduleAggregatorAgent = 'schedule_aggregator_agent';
  static const String scheduleRefreshRouterAgent =
      'schedule_refresh_router_agent';
  static const String commentAgent = 'comment_agent';
  static const String chatAgent = 'chat_agent';
  static const String analyzeAssets = 'analyze_assets';
  static const String clarificationResolutionAgent =
      'clarification_resolution_agent';

  static const Map<String, String> displayNames = {
    pkmAgent: 'PKM',
    cardAgent: 'Cards',
    profileAgent: 'Memory summary',
    knowledgeInsightAgent: 'Insights',
    scheduleAggregatorAgent: 'Schedule',
    scheduleRefreshRouterAgent: 'Schedule Router',
    commentAgent: 'Comments',
    chatAgent: 'Chat',
    analyzeAssets: 'Media analysis',
    clarificationResolutionAgent: 'Ask resolution',
  };
}

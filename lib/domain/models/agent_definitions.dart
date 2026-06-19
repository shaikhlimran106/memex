class AgentDefinitions {
  static const String commentAgent = 'comment_agent';
  static const String chatAgent = 'chat_agent';
  static const String companionAgent = 'companion_agent';
  static const String profileAgent = 'profile_agent';

  /// Order here drives the display order in the agent configuration screen.
  static const Map<String, String> displayNames = {
    commentAgent: 'Comments',
    chatAgent: 'Chat',
    companionAgent: 'Companion',
    profileAgent: 'Memory summary',
  };

  /// Agent IDs exposed in the model configuration screen.
  ///
  /// Keeping this derived from the display-name registry makes the settings UI
  /// pick up newly registered built-in agents automatically.
  static List<String> get configurableAgentIds =>
      List.unmodifiable(displayNames.keys);
}

/// Run mode for the SuperAgent direct-entry experience, similar to
/// Claude Code's permission modes.
///
/// - [auto]: mutating tools execute immediately (current default behavior).
/// - [confirm]: every mutating tool call pauses and waits for explicit
///   in-chat user approval before executing.
/// - [readOnly]: maps to the existing quick-query path; mutating skills and
///   tools are not offered to the model at all.
enum AgentRunMode {
  auto('auto'),
  confirm('confirm'),
  readOnly('read_only');

  const AgentRunMode(this.wireName);

  /// Stable string used in agent state metadata and persistence.
  final String wireName;

  /// Key under which the active run mode is stored in `AgentState.metadata`.
  static const String metadataKey = 'run_mode';

  static AgentRunMode fromWire(String? value) {
    for (final mode in values) {
      if (mode.wireName == value) return mode;
    }
    return AgentRunMode.auto;
  }
}

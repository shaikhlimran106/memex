import 'package:flutter/material.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/ui/chat/widgets/agent_chat_dialog.dart';
import 'package:memex/utils/result.dart';
import 'package:memex/utils/user_storage.dart';

Future<String?> latestSuperAgentSessionId() async {
  try {
    final result = await MemexRouter().fetchChatSessions(
      agentName: 'memex_agent',
      limit: 30,
    );
    return result.when(
      onOk: (sessions) {
        for (final session in sessions) {
          if (session['scene'] == 'super_agent_home') {
            return session['session_id']?.toString();
          }
        }
        return null;
      },
      onError: (_, __) => null,
    );
  } catch (_) {
    return null;
  }
}

void openSuperAgentDialog(
  BuildContext context, {
  String? initialDraftText,
  String? sceneId,
  List<Map<String, String>>? initialRefs,
}) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: '',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 500),
    pageBuilder: (context, animation, secondaryAnimation) {
      return FutureBuilder<String?>(
        future: latestSuperAgentSessionId(),
        builder: (context, snapshot) {
          final sessionId = snapshot.data;
          return AgentChatDialog(
            key: ValueKey(sessionId ?? 'super_agent_new_session'),
            agentName: 'memex_agent',
            title: 'Memex',
            initialSessionId: sessionId,
            inputHint: UserStorage.l10n.aiInputHint,
            scene: 'super_agent_home',
            sceneId: sceneId,
            initialRefs: initialRefs,
            initialDraftText: initialDraftText,
          );
        },
      );
    },
  );
}

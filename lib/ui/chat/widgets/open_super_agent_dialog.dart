import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:memex/data/repositories/memex_router.dart';
import 'package:memex/ui/chat/widgets/agent_chat_dialog.dart';
import 'package:memex/utils/result.dart';

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
  List<XFile> initialImages = const [],
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
            initialSessionId: sessionId,
            sceneId: sceneId,
            initialRefs: initialRefs,
            initialDraftText: initialDraftText,
            initialImages: initialImages,
          );
        },
      );
    },
  );
}

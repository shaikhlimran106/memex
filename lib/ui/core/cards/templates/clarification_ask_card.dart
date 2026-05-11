import 'package:flutter/material.dart';
import 'package:memex/data/services/clarification_request_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/ui/card_attachments/widgets/clarification_request_card.dart';

/// Timeline card template for global Ask (clarification requests without a
/// parent card). Stored as a regular timeline card file with
/// `templateId: 'clarification_ask'` and `data: {'request_id': '...'}`.
///
/// Loads the request from the DB on build. Updates are handled by the normal
/// card update flow: [ClarificationRequestService] emits [CardUpdatedMessage]
/// when the request status changes, which causes [TimelineViewModel] to
/// replace this card, triggering a rebuild with fresh data.
class ClarificationAskCard extends StatefulWidget {
  final Map<String, dynamic> data;

  const ClarificationAskCard({super.key, required this.data});

  @override
  State<ClarificationAskCard> createState() => _ClarificationAskCardState();
}

class _ClarificationAskCardState extends State<ClarificationAskCard> {
  ClarificationRequest? _request;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final requestId = widget.data['request_id'] as String?;
    if (requestId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final request =
        await ClarificationRequestService.instance.getRequest(requestId);
    if (!mounted) return;
    setState(() {
      _request = request;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 80,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final request = _request;
    if (request == null) {
      return const SizedBox.shrink();
    }

    return ClarificationRequestCard(
      request: request,
      service: ClarificationRequestService.instance,
    );
  }
}

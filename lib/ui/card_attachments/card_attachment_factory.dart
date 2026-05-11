import 'package:flutter/widgets.dart';
import 'package:memex/data/services/system_action_service.dart';
import 'package:memex/data/services/clarification_request_service.dart';
import 'package:memex/db/app_database.dart';
import 'package:memex/ui/card_attachments/card_attachment_data.dart';
import 'package:memex/data/services/card_attachment_service.dart';
import 'package:memex/ui/card_attachments/widgets/system_action_card.dart';
import 'package:memex/ui/card_attachments/widgets/clarification_request_card.dart';
import 'package:memex/ui/card_attachments/widgets/card_detail_notification_widget.dart';

/// Builds a widget for a [CardAttachmentData] item.
///
/// Works like [NativeCardFactory] — a static `build` method that dispatches
/// on [CardAttachmentData.type]. Adding a new attachment type means adding
/// one case here and one widget file in `widgets/`.
class CardAttachmentFactory {
  static Widget build(CardAttachmentData attachment) {
    switch (attachment.type) {
      case CardAttachmentType.systemAction:
        return SystemActionCard(
          action: attachment.data['action'],
          service: SystemActionService.instance,
        );

      case CardAttachmentType.clarificationRequest:
        return ClarificationRequestCard(
          request: attachment.data['request'],
          service: ClarificationRequestService.instance,
        );

      case CardAttachmentType.cardDetailNotification:
        return CardDetailNotificationWidget(
          notification: attachment.data['notification'] as UserNotification,
        );

      default:
        return const SizedBox.shrink();
    }
  }
}

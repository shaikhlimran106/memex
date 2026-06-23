// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';
import 'app_localizations_ext_ar.dart';
import 'app_localizations_ext_de.dart';
import 'app_localizations_ext_en.dart';
import 'app_localizations_ext_es.dart';
import 'app_localizations_ext_fr.dart';
import 'app_localizations_ext_hi.dart';
import 'app_localizations_ext_id.dart';
import 'app_localizations_ext_ja.dart';
import 'app_localizations_ext_ko.dart';
import 'app_localizations_ext_pt.dart';
import 'app_localizations_ext_ru.dart';
import 'app_localizations_ext_zh.dart';
import 'app_localizations_ext_zh_hant.dart';
import 'package:flutter/material.dart';

// ignore_for_file: type=lint

/// The extension for AppLocalizations.
mixin AppLocalizationsExt on AppLocalizations {
  String get pkmPARAStructureExample;
  String get timelineCardLanguageInstruction;
  String get pkmFileLanguageInstruction;
  String get pkmInsightLanguageInstruction;
  String get commentLanguageInstruction;
  String get knowledgeInsightLanguageInstruction;
  String get scheduleAggregatorLanguageInstruction;
  String get assetAnalysisLanguageInstruction;

  String get userLanguageInstruction;

  String get chatLanguageInstruction;

  String get memorySummarizeLanguageInstruction;

  String get memorySummarizeIdentityHeader;

  String get memorySummarizeInterestsHeader;

  String get memorySummarizeAssetsHeader;

  String get memorySummarizeFocusHeader;

  /// Android OAuth hint dialog (before opening browser).
  String get oauthHintTitle;
  String get oauthHintMessage;

  /// OAuth success page (HTML) after redirect.
  String get oauthSuccessTitle;
  String get oauthSuccessMessage;

  /// Share poster localization.
  String get sharePreviewTitle;
  String get shareNow;
  String get sharedFromMemex;
  String get appTagline;
  String get shareDetailStyle;
  String get shareCardStyle;
  String get shareHideBranding;
  String get shareShowBranding;

  /// Default built-in characters (used to seed `Characters/*.yaml`).
  List<Map<String, dynamic>> get defaultCharacters;
}

/// Standalone function to lookup AppLocalizationsExt instances by locale.
AppLocalizationsExt lookupAppLocalizationsExt(Locale locale) {
  // Lookup logic when language+script codes are specified.
  if (locale.languageCode == 'zh' &&
      (locale.scriptCode == 'Hant' ||
          locale.countryCode == 'Hant' ||
          locale.countryCode == 'TW' ||
          locale.countryCode == 'HK' ||
          locale.countryCode == 'MO')) {
    return AppLocalizationsExtZhHant();
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsExtAr();
    case 'de':
      return AppLocalizationsExtDe();
    case 'en':
      return AppLocalizationsExtEn();
    case 'es':
      return AppLocalizationsExtEs();
    case 'fr':
      return AppLocalizationsExtFr();
    case 'hi':
      return AppLocalizationsExtHi();
    case 'id':
      return AppLocalizationsExtId();
    case 'ja':
      return AppLocalizationsExtJa();
    case 'ko':
      return AppLocalizationsExtKo();
    case 'pt':
      return AppLocalizationsExtPt();
    case 'ru':
      return AppLocalizationsExtRu();
    case 'zh':
      return AppLocalizationsExtZh();
  }

  throw FlutterError(
      'AppLocalizationsExt.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}

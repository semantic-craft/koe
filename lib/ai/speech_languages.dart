class SpeechLanguage {
  const SpeechLanguage(this.code, this.name);

  final String code;
  final String name;

  String get label => '$name（$code）';
}

/// Language names retained for displaying historical translation settings.
const speechLanguages = <SpeechLanguage>[
  SpeechLanguage('af', 'Afrikaans'),
  SpeechLanguage('sq', 'Albanian'),
  SpeechLanguage('ar', 'Arabic'),
  SpeechLanguage('az', 'Azerbaijani'),
  SpeechLanguage('eu', 'Basque'),
  SpeechLanguage('be', 'Belarusian'),
  SpeechLanguage('bn', 'Bengali'),
  SpeechLanguage('bs', 'Bosnian'),
  SpeechLanguage('bg', 'Bulgarian'),
  SpeechLanguage('ca', 'Catalan'),
  SpeechLanguage('zh', '中文'),
  SpeechLanguage('zh-cn', '中文（简体）'),
  SpeechLanguage('zh-hans', '中文（简体）'),
  SpeechLanguage('hr', 'Croatian'),
  SpeechLanguage('cs', 'Czech'),
  SpeechLanguage('da', 'Danish'),
  SpeechLanguage('nl', 'Dutch'),
  SpeechLanguage('en', 'English'),
  SpeechLanguage('en-us', 'English'),
  SpeechLanguage('et', 'Estonian'),
  SpeechLanguage('fi', 'Finnish'),
  SpeechLanguage('fr', 'French'),
  SpeechLanguage('gl', 'Galician'),
  SpeechLanguage('de', 'German'),
  SpeechLanguage('el', 'Greek'),
  SpeechLanguage('gu', 'Gujarati'),
  SpeechLanguage('he', 'Hebrew'),
  SpeechLanguage('hi', 'Hindi'),
  SpeechLanguage('hu', 'Hungarian'),
  SpeechLanguage('id', 'Indonesian'),
  SpeechLanguage('it', 'Italian'),
  SpeechLanguage('ja', '日本語'),
  SpeechLanguage('ja-jp', '日本語'),
  SpeechLanguage('kn', 'Kannada'),
  SpeechLanguage('kk', 'Kazakh'),
  SpeechLanguage('ko', '한국어'),
  SpeechLanguage('lv', 'Latvian'),
  SpeechLanguage('lt', 'Lithuanian'),
  SpeechLanguage('mk', 'Macedonian'),
  SpeechLanguage('ms', 'Malay'),
  SpeechLanguage('ml', 'Malayalam'),
  SpeechLanguage('mr', 'Marathi'),
  SpeechLanguage('no', 'Norwegian'),
  SpeechLanguage('fa', 'Persian'),
  SpeechLanguage('pl', 'Polish'),
  SpeechLanguage('pt', 'Portuguese'),
  SpeechLanguage('pa', 'Punjabi'),
  SpeechLanguage('ro', 'Romanian'),
  SpeechLanguage('ru', 'Russian'),
  SpeechLanguage('sr', 'Serbian'),
  SpeechLanguage('sk', 'Slovak'),
  SpeechLanguage('sl', 'Slovenian'),
  SpeechLanguage('es', 'Spanish'),
  SpeechLanguage('sw', 'Swahili'),
  SpeechLanguage('sv', 'Swedish'),
  SpeechLanguage('tl', 'Tagalog'),
  SpeechLanguage('ta', 'Tamil'),
  SpeechLanguage('te', 'Telugu'),
  SpeechLanguage('th', 'Thai'),
  SpeechLanguage('tr', 'Turkish'),
  SpeechLanguage('uk', 'Ukrainian'),
  SpeechLanguage('ur', 'Urdu'),
  SpeechLanguage('vi', 'Vietnamese'),
  SpeechLanguage('cy', 'Welsh'),
];

SpeechLanguage speechLanguageFor(String code) {
  final normalized = code.trim().replaceAll('_', '-').toLowerCase();
  return speechLanguages.firstWhere(
    (language) => language.code == normalized,
    orElse: () => SpeechLanguage(normalized, normalized.toUpperCase()),
  );
}

bool isSpeechLanguage(String code) {
  final normalized = code.trim().replaceAll('_', '-').toLowerCase();
  return speechLanguages.any((language) => language.code == normalized);
}

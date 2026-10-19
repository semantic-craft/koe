import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Koe speaks Chinese only: Material's own strings (返回、显示菜单、日期和
/// 时间选择器) and screen-reader names follow it whatever the system
/// language is (#237).
const koeLocale = Locale('zh', 'CN');

const koeLocalizationsDelegates = <LocalizationsDelegate<Object>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

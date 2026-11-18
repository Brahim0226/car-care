import 'package:flutter/widgets.dart';

/// اللغة الحالية للتطبيق: 'ar' (العربية) أو 'fr' (Français)
class Lang {
  static String code = 'ar';
  static bool get fr => code == 'fr';
  static TextDirection get dir => fr ? TextDirection.ltr : TextDirection.rtl;
  static TextAlign get start => fr ? TextAlign.left : TextAlign.right;
}

/// يرجع النص بالعربية أو بالفرنسية حسب اللغة المختارة
String t(String ar, String fr) => Lang.fr ? fr : ar;

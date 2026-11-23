import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'l10n.dart';
import 'main.dart';

void _snack(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// يحفظ كل البيانات في ملف .json ويفتح قائمة المشاركة (واتساب، Drive، بريد…)
Future<void> shareBackupFile(BuildContext context, Store store) async {
  try {
    final dir = await getTemporaryDirectory();
    final n = DateTime.now();
    final name =
        'entretien-backup-${n.year}${n.month.toString().padLeft(2, '0')}${n.day.toString().padLeft(2, '0')}.json';
    final f = File('${dir.path}/$name');
    await f.writeAsString(store.exportJson());
    await Share.shareXFiles([XFile(f.path)],
        text: t('نسخة احتياطية من تطبيق صيانة سيارتي', "Sauvegarde de l'application d'entretien auto"));
  } catch (_) {
    _snack(context, t('تعذّر إنشاء الملف', "Impossible de créer le fichier"));
  }
}

/// يستعيد البيانات من ملف .json اختاره المستخدم (يستبدل البيانات الحالية)
Future<void> restoreBackupFile(BuildContext context, Store store) async {
  try {
    final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    if (r == null || r.files.isEmpty) return;
    final bytes = r.files.single.bytes;
    if (bytes == null) {
      _snack(context, t('تعذّر قراءة الملف', "Impossible de lire le fichier"));
      return;
    }
    if (!context.mounted) return;
    final ok = await confirm(context,
        t('سيتم استبدال البيانات الحالية بمحتوى الملف. متابعة؟', "Les données actuelles seront remplacées par le fichier. Continuer ?"));
    if (!ok) return;
    final done = store.importJson(utf8.decode(bytes));
    _snack(context, done ? t('تمت الاستعادة بنجاح', "Restauration réussie") : t('الملف غير صالح', "Fichier invalide"));
  } catch (_) {
    _snack(context, t('الملف غير صالح', "Fichier invalide"));
  }
}

/// يشارك رابط تحميل التطبيق مع الأصدقاء (نص عربي وفرنسي)
Future<void> shareApp(BuildContext context) async {
  const link = 'https://github.com/Brahim0226/car-care/releases/latest/download/car-care.apk';
  try {
    await Share.share(
      'صيانة سيارتي: تطبيق مجاني يذكّرك بموعد الفيدانج والتأمين والمراقبة التقنية.\n'
      'حمّله من هنا: $link\n\n'
      "Mon Entretien Auto : application gratuite qui vous rappelle la vidange, l'assurance et le contrôle technique.\n"
      'Télécharger : $link',
    );
  } catch (_) {
    _snack(context, t('تعذّرت المشاركة', "Partage impossible"));
  }
}

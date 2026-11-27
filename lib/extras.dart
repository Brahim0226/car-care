import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'backup.dart';
import 'l10n.dart';
import 'main.dart';
import 'sync.dart';

void _snack(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// يفتح تطبيق التقويم لإضافة موعد (يؤكد المستخدم الحفظ بنفسه)
Future<void> addToCalendar(BuildContext context, String title, DateTime when) async {
  try {
    final start = DateTime(when.year, when.month, when.day, 9);
    await AndroidIntent(
      action: 'android.intent.action.INSERT',
      data: 'content://com.android.calendar/events',
      arguments: <String, dynamic>{
        'title': title,
        'beginTime': start.millisecondsSinceEpoch,
        'endTime': start.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      },
    ).launch();
  } catch (_) {
    _snack(context, t('لم أجد تطبيق تقويم في الهاتف', "Aucune application Agenda trouvée sur le téléphone"));
  }
}

/// يبحث في الخرائط عن ورشة/محطة بنزين/محل قطع غيار قريب
Future<void> searchNearby(BuildContext context, String query) async {
  final q = Uri.encodeComponent(query);
  try {
    var ok = await launchUrl(Uri.parse('geo:0,0?q=$q'),
        mode: LaunchMode.externalApplication);
    if (!ok) {
      ok = await launchUrl(
          Uri.parse('https://www.google.com/maps/search/?api=1&query=$q'),
          mode: LaunchMode.externalApplication);
    }
    if (!ok) _snack(context, t('تعذّر فتح الخرائط', "Impossible d'ouvrir les cartes"));
  } catch (_) {
    _snack(context, t('تعذّر فتح الخرائط', "Impossible d'ouvrir les cartes"));
  }
}

void nearbyDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(t('ابحث بالقرب منك', "Chercher près de vous")),
      children: [
        ListTile(
          leading: const Icon(Icons.build_circle_outlined),
          title: Text(t('ورشة ميكانيك', "Garage mécanique")),
          onTap: () {
            Navigator.pop(ctx);
            searchNearby(context, t('ورشة ميكانيك', 'garage mécanique'));
          },
        ),
        ListTile(
          leading: const Icon(Icons.local_gas_station),
          title: Text(t('محطة وقود', "Station-service")),
          onTap: () {
            Navigator.pop(ctx);
            searchNearby(context, t('محطة وقود', 'station-service'));
          },
        ),
        ListTile(
          leading: const Icon(Icons.settings_suggest_outlined),
          title: Text(t('محل قطع غيار', "Magasin de pièces auto")),
          onTap: () {
            Navigator.pop(ctx);
            searchNearby(context, t('قطع غيار السيارات', 'pièces auto'));
          },
        ),
        ListTile(
          leading: const Icon(Icons.local_car_wash),
          title: Text(t('غسل السيارات', "Lavage auto")),
          onTap: () {
            Navigator.pop(ctx);
            searchNearby(context, t('غسل السيارات', 'lavage auto'));
          },
        ),
      ],
    ),
  );
}

/// يلتقط/يختار صورة فاتورة وينسخها لمجلد التطبيق، ويرجع مسارها (أو null)
Future<String?> pickInvoicePhoto(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: Text(t('التقاط صورة', "Prendre une photo")),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: Text(t('من المعرض', "Depuis la galerie")),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null) return null;
  try {
    final x = await ImagePicker()
        .pickImage(source: source, maxWidth: 1600, imageQuality: 80);
    if (x == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/invoices');
    if (!await folder.exists()) await folder.create(recursive: true);
    final dest = '${folder.path}/${DateTime.now().microsecondsSinceEpoch}.jpg';
    await File(x.path).copy(dest);
    return dest;
  } catch (_) {
    _snack(context, t('تعذّر الحصول على الصورة', "Impossible d'obtenir la photo"));
    return null;
  }
}

void showPhoto(BuildContext context, String path) {
  final f = File(path);
  if (!f.existsSync()) {
    _snack(context, t('الصورة غير موجودة على هذا الهاتف', "La photo n'existe pas sur ce téléphone"));
    return;
  }
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      child: InteractiveViewer(child: Image.file(f)),
    ),
  );
}

const apkLink = 'https://github.com/Brahim0226/car-care/releases/latest/download/car-care.apk';

/// ينزّل الـAPK داخل التطبيق ثم يفتح شاشة التثبيت مباشرة (مع احتياط: فتح رابط التحميل)
Future<void> downloadAndInstall(BuildContext context) async {
  final progress = ValueNotifier<double?>(0);
  var cancelled = false;
  var dialogOpen = true;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(t('جارٍ تنزيل التحديث', 'Téléchargement de la mise à jour')),
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: v),
          const SizedBox(height: 8),
          Text(v == null ? '…' : '${(v * 100).round()}%'),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            dialogOpen = false;
            Navigator.pop(ctx);
          },
          child: Text(t('إلغاء', 'Annuler')),
        ),
      ],
    ),
  );
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/car-care-update.apk');
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(apkLink)));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final total = resp.contentLength ?? 0;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in resp.stream) {
        if (cancelled) break;
        sink.add(chunk);
        got += chunk.length;
        progress.value = total > 0 ? got / total : null;
      }
      await sink.close();
      if (cancelled) return;
    } finally {
      client.close();
    }
    if (dialogOpen && context.mounted) Navigator.of(context, rootNavigator: true).pop();
    dialogOpen = false;
    final r = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
    if (r.type != ResultType.done) throw Exception(r.message);
  } catch (_) {
    if (dialogOpen && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      dialogOpen = false;
    }
    if (!cancelled) {
      await launchUrl(Uri.parse(apkLink), mode: LaunchMode.externalApplication);
    }
  }
}

/// عند فتح الشاشة الرئيسية: إشعار بإصدار جديد، أو (مرة واحدة بعد أسبوعين) دعوة للمشاركة
Future<void> startupPrompts(BuildContext context, Store store) async {
  try {
    final prefs = store.prefs;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (prefs.getInt('firstRun') == null) await prefs.setInt('firstRun', now);

    // نتيجة آخر فحص محفوظة، وتُجدَّد كل ساعة تقريباً
    String? v = prefs.getString('newVer');
    if (v != null && !isNewerVersion(v)) v = null;
    final last = prefs.getInt('lastUpdateCheck') ?? 0;
    if (now - last > 3600 * 1000) {
      final fetched = await fetchLatestVersion();
      await prefs.setString('updDiag',
          '${DateTime.now().toIso8601String().substring(0, 16)} → ${fetched ?? 'فشل'} (${updateDiag})');
      if (fetched != null) {
        await prefs.setInt('lastUpdateCheck', now);
        v = isNewerVersion(fetched) ? fetched : null;
        if (v == null) {
          await prefs.remove('newVer');
        } else {
          await prefs.setString('newVer', v);
        }
      }
    }
    if (v != null) {
      if (!context.mounted) return;
      if (prefs.getString('updateShown') != v) {
        await prefs.setString('updateShown', v);
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t('إصدار جديد: $v', "Nouvelle version : $v")),
            content: Text(t('يوجد تحديث للتطبيق. حمّله وثبّته فوق النسخة الحالية، وبياناتك تبقى.',
                "Une mise à jour est disponible. Téléchargez-la et installez-la par-dessus : vos données restent.")),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('لاحقاً', "Plus tard"))),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  downloadAndInstall(context);
                },
                child: Text(t('تحميل', "Télécharger")),
              ),
            ],
          ),
        );
      }
      if (!context.mounted) return;
      final sm = ScaffoldMessenger.of(context);
      sm.hideCurrentMaterialBanner();
      sm.showMaterialBanner(MaterialBanner(
        content: Text(t('إصدار جديد $v متوفر', "Nouvelle version $v disponible")),
        leading: const Icon(Icons.system_update),
        actions: [
          TextButton(
            onPressed: () => downloadAndInstall(context),
            child: Text(t('تحميل', 'Télécharger')),
          ),
          TextButton(onPressed: sm.hideCurrentMaterialBanner, child: Text(t('إخفاء', 'Masquer'))),
        ],
      ));
      return;
    }

    final first = prefs.getInt('firstRun') ?? now;
    if (now - first > 14 * 24 * 3600 * 1000 && !(prefs.getBool('sharePrompted') ?? false)) {
      await prefs.setBool('sharePrompted', true);
      if (!context.mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('أعجبك التطبيق؟', "Vous aimez l'application ?")),
          content: Text(t('شاركه مع أصدقائك أصحاب السيارات، فيستفيدون مثلك.',
              "Partagez-la avec vos amis automobilistes, ils en profiteront aussi.")),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('لاحقاً', "Plus tard"))),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                shareApp(context);
              },
              child: Text(t('شارك', "Partager")),
            ),
          ],
        ),
      );
    }
  } catch (_) {}
}

import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'l10n.dart';
import 'main.dart';

/// تنبيهات الصيانة:
/// - بالتاريخ: إشعار مجدول قبل الموعد بأسبوع وفي يوم الموعد (الساعة 9 صباحاً)
/// - بالكيلومتر: إشعار فوري عند فتح التطبيق أو تحديث العداد إذا اقترب البند أو تجاوز موعده
class Notifier {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool ready = false;
  static bool _busy = false;
  static bool _again = false;

  static NotificationDetails get _details => NotificationDetails(
    android: AndroidNotificationDetails(
      'maintenance',
      t('تنبيهات الصيانة', "Alertes d'entretien"),
      channelDescription: t('تذكيرات مواعيد صيانة السيارة', "Rappels des échéances d'entretien de la voiture"),
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  static Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Africa/Algiers'));
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings);
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      ready = true;
    } catch (_) {
      ready = false;
    }
  }

  /// إشعار تجريبي للتأكد من أن التنبيهات تعمل على الهاتف
  static Future<bool> test() async {
    if (!ready) return false;
    try {
      await _plugin.show(
          1, t('تنبيه تجريبي', "Notification de test"), t('التنبيهات تعمل بنجاح ✅', "Les notifications fonctionnent ✅"), _details);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> sync(Store store) async {
    if (!ready) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        await _run(store);
      } while (_again);
    } catch (_) {
      // التنبيهات اختيارية: لا نوقف التطبيق إذا فشلت
    } finally {
      _busy = false;
    }
  }

  static Future<void> _run(Store store) async {
    // نلغي فقط الإشعارات المجدولة (المنتظرة) ونعيد جدولتها
    final pending = await _plugin.pendingNotificationRequests();
    for (final p in pending) {
      await _plugin.cancel(p.id);
    }

    final now = DateTime.now();
    var id = 100;
    final multi = store.cars.length > 1;
    for (final car in store.cars) {
      final tag = multi ? ' • ${car.label}' : '';
      for (final it in car.items) {
        final last = car.lastService(it.id);
        if (last == null || it.intervalMonths <= 0) continue;
        final due = DateTime(last.date.year,
            last.date.month + it.intervalMonths, last.date.day, 9);
        final before = due.subtract(const Duration(days: 7));
        await _schedule(
          id++,
          t('اقترب موعد: ${it.label}$tag', "Échéance proche : ${it.label}$tag"),
          t('باقي أسبوع على موعد الصيانة (${fmtDate(due)})', "Plus qu'une semaine avant l'entretien (${fmtDate(due)})"),
          before,
          now,
        );
        await _schedule(
          id++,
          t('حان موعد: ${it.label}$tag', "C'est l'heure : ${it.label}$tag"),
          t('موعد الصيانة اليوم (${fmtDate(due)})', "Entretien prévu aujourd'hui (${fmtDate(due)})"),
          due,
          now,
        );
      }
    }

    await _checkKm(store);
  }

  static Future<void> _schedule(
    int id,
    String title,
    String body,
    DateTime when,
    DateTime now,
  ) async {
    if (!when.isAfter(now)) return;
    final at = tz.TZDateTime.from(when, tz.local);
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      at,
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  static Future<void> _checkKm(Store store) async {
    Map<String, dynamic> shown = {};
    try {
      shown = jsonDecode(store.prefs.getString('kmNotified') ?? '{}')
          as Map<String, dynamic>;
    } catch (_) {}

    final next = <String, dynamic>{};
    final multi = store.cars.length > 1;
    var n = 0;
    for (final car in store.cars) {
      final tag = multi ? ' • ${car.label}' : '';
      for (final it in car.items) {
        if (it.intervalKm <= 0) continue;
        final last = car.lastService(it.id);
        if (last == null) continue;
        final rem = last.km + it.intervalKm - car.km;
        final lvl = rem < 0 ? 2 : (rem <= it.intervalKm ~/ 10 ? 1 : 0);
        if (lvl == 0) continue; // رجع عادي: نصفّر التتبع لهذا البند
        final key = '${car.id}:${it.id}';
        final prev = (shown[key] as num?)?.toInt() ?? 0;
        next[key] = lvl > prev ? lvl : prev;
        if (lvl > prev) {
          final title = lvl == 2
              ? t('تجاوزت موعد: ${it.label}$tag', "Échéance dépassée : ${it.label}$tag")
              : t('اقترب موعد: ${it.label}$tag', "Échéance proche : ${it.label}$tag");
          final body = lvl == 2
              ? t('تجاوزت ${fmt(-rem)} كم، يُفضَّل إجراء الصيانة قريباً', "Dépassé de ${fmt(-rem)} km, entretien conseillé bientôt")
              : t('باقي ${fmt(rem)} كم على الصيانة', "Plus que ${fmt(rem)} km avant l'entretien");
          await _plugin.show(5000 + n, title, body, _details);
        }
        n++;
      }
    }
    await store.prefs.setString('kmNotified', jsonEncode(next));
  }
}

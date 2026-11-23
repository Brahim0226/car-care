import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'charts.dart';
import 'docs.dart';
import 'admin.dart';
import 'backup.dart';
import 'extras.dart';
import 'fuel.dart';
import 'l10n.dart';
import 'notifications.dart';
import 'report.dart';
import 'sync.dart';

// ====================== أدوات مساعدة ======================

String normDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(r - 0x0660 + 0x30);
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(r - 0x06F0 + 0x30);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

int? parseInt(String s) =>
    int.tryParse(normDigits(s).replaceAll(RegExp(r'[\s,]'), ''));

double? parseDouble(String s) =>
    double.tryParse(normDigits(s).replaceAll(',', '.').replaceAll(RegExp(r'\s'), ''));

// نستعمل مسافة غير منقسمة (NBSP) كفاصل آلاف: في النص العربي (RTL) المسافة العادية
// تجعل مجموعات الأرقام تنعكس (514 943 تظهر 943 514)، أما NBSP فتبقي الرقم متصلاً.
String fmt(int n) => n
    .toString()
    .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ' ');

String fmtDate(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

String fmtMoney(double v) => t('${fmt(v.round())} دج', "${fmt(v.round())} DA");

String numText(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

Future<bool> confirm(BuildContext context, String msg) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('إلغاء', "Annuler"))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('تأكيد', "Confirmer"))),
      ],
    ),
  );
  return r ?? false;
}

IconData iconFor(String id) {
  switch (id) {
    case 'oil':
      return Icons.opacity;
    case 'oil_filter':
    case 'air_filter':
    case 'fuel_filter':
      return Icons.filter_alt;
    case 'cabin_filter':
      return Icons.ac_unit;
    case 'tires':
      return Icons.tire_repair;
    case 'brakes':
      return Icons.stop_circle;
    case 'spark':
      return Icons.flash_on;
    case 'battery':
      return Icons.battery_charging_full;
    case 'belt':
      return Icons.settings;
    default:
      return Icons.build;
  }
}

// ====================== النماذج ======================

/// أسماء البنود الافتراضية بالعربية والفرنسية (تُعرض حسب اللغة ما لم يغيّر المستخدم الاسم)
const Map<String, List<String>> defaultNames = {
  'oil': ['زيت المحرك', 'Huile moteur'],
  'oil_filter': ['فلتر الزيت', 'Filtre à huile'],
  'air_filter': ['فلتر الهواء', 'Filtre à air'],
  'fuel_filter': ['فلتر الوقود (مازوط/بنزين)', 'Filtre à carburant (gasoil/essence)'],
  'cabin_filter': ['فلتر المكيّف', "Filtre d'habitacle (clim)"],
  'belt': ['سير/سلسلة التوزيع (لاشان)', 'Courroie/chaîne de distribution'],
  'tires': ['العجلات', 'Pneus'],
  'brakes': ['الفرامل (بلاكات)', 'Freins (plaquettes)'],
  'spark': ['شمعات الإشعال', "Bougies d'allumage"],
  'battery': ['البطارية', 'Batterie'],
};

class Item {
  final String id;
  String name;
  int intervalKm;
  int intervalMonths;

  Item({
    required this.id,
    required this.name,
    required this.intervalKm,
    required this.intervalMonths,
  });

  /// الاسم المعروض حسب اللغة
  String get label {
    final d = defaultNames[id];
    if (d != null && (name == d[0] || name == d[1])) return t(d[0], d[1]);
    return name;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'intervalKm': intervalKm,
        'intervalMonths': intervalMonths,
      };

  factory Item.fromJson(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        name: j['name'] as String,
        intervalKm: (j['intervalKm'] as num?)?.toInt() ?? 0,
        intervalMonths: (j['intervalMonths'] as num?)?.toInt() ?? 0,
      );
}

class Service {
  final String itemId;
  final DateTime date;
  final int km;
  final double cost;
  final String note;
  final String? photo;

  Service({
    required this.itemId,
    required this.date,
    required this.km,
    required this.cost,
    required this.note,
    this.photo,
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'date': date.toIso8601String(),
        'km': km,
        'cost': cost,
        'note': note,
        'photo': photo,
      };

  factory Service.fromJson(Map<String, dynamic> j) => Service(
        itemId: j['itemId'] as String,
        date: DateTime.parse(j['date'] as String),
        km: (j['km'] as num).toInt(),
        cost: (j['cost'] as num).toDouble(),
        note: j['note'] as String? ?? '',
        photo: j['photo'] as String?,
      );
}

enum Level { overdue, soon, none, ok }

class Status {
  final Level level;
  final String text;
  const Status(this.level, this.text);

  Color get color {
    switch (level) {
      case Level.overdue:
        return Colors.red;
      case Level.soon:
        return Colors.orange;
      case Level.ok:
        return Colors.green;
      case Level.none:
        return Colors.grey;
    }
  }
}

List<Item> defaultItems() => [
      Item(id: 'oil', name: 'زيت المحرك', intervalKm: 10000, intervalMonths: 6),
      Item(id: 'oil_filter', name: 'فلتر الزيت', intervalKm: 10000, intervalMonths: 6),
      Item(id: 'air_filter', name: 'فلتر الهواء', intervalKm: 15000, intervalMonths: 12),
      Item(id: 'fuel_filter', name: 'فلتر الوقود (مازوط/بنزين)', intervalKm: 20000, intervalMonths: 12),
      Item(id: 'cabin_filter', name: 'فلتر المكيّف', intervalKm: 15000, intervalMonths: 12),
      Item(id: 'belt', name: 'سير/سلسلة التوزيع (لاشان)', intervalKm: 80000, intervalMonths: 60),
      Item(id: 'tires', name: 'العجلات', intervalKm: 40000, intervalMonths: 48),
      Item(id: 'brakes', name: 'الفرامل (بلاكات)', intervalKm: 30000, intervalMonths: 24),
      Item(id: 'spark', name: 'شمعات الإشعال', intervalKm: 30000, intervalMonths: 24),
      Item(id: 'battery', name: 'البطارية', intervalKm: 0, intervalMonths: 36),
    ];

/// سيارة: لها بنودها وسجل صيانتها وعدادها وسعر شرائها (اختياري)
class Car {
  final String id;
  String name;
  int km;
  double? purchasePrice;
  List<Item> items;
  List<Service> services;
  List<FuelEntry> fuel;
  List<CarDoc> docs;

  Car({
    required this.id,
    required this.name,
    this.km = 0,
    this.purchasePrice,
    List<Item>? items,
    List<Service>? services,
    List<FuelEntry>? fuel,
    List<CarDoc>? docs,
  })  : items = items ?? defaultItems(),
        services = services ?? [],
        fuel = fuel ?? [],
        docs = docs ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'km': km,
        'purchasePrice': purchasePrice,
        'items': items.map((e) => e.toJson()).toList(),
        'services': services.map((e) => e.toJson()).toList(),
        'fuel': fuel.map((e) => e.toJson()).toList(),
        'docs': docs.map((e) => e.toJson()).toList(),
      };

  factory Car.fromJson(Map<String, dynamic> j) => Car(
        id: j['id'] as String,
        name: j['name'] as String? ?? t('سيارتي', "Ma voiture"),
        km: (j['km'] as num?)?.toInt() ?? 0,
        purchasePrice: (j['purchasePrice'] as num?)?.toDouble(),
        items: ((j['items'] as List?) ?? [])
            .map((e) => Item.fromJson(e as Map<String, dynamic>))
            .toList(),
        services: ((j['services'] as List?) ?? [])
            .map((e) => Service.fromJson(e as Map<String, dynamic>))
            .toList(),
        fuel: ((j['fuel'] as List?) ?? [])
            .map((e) => FuelEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        docs: ((j['docs'] as List?) ?? [])
            .map((e) => CarDoc.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// اسم السيارة المعروض (الاسم الافتراضي يُترجم حسب اللغة)
  String get label =>
      (name == 'سيارتي' || name == 'Ma voiture') ? t('سيارتي', 'Ma voiture') : name;

  Item? itemById(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  Service? lastService(String id) {
    Service? best;
    for (final s in services) {
      if (s.itemId != id) continue;
      if (best == null ||
          s.date.isAfter(best.date) ||
          (s.date == best.date && s.km > best.km)) {
        best = s;
      }
    }
    return best;
  }

  double get maintenanceCost => services.fold<double>(0, (a, s) => a + s.cost);

  /// ثمن الشراء (إن وُجد) + مصاريف الصيانة
  double get totalCost => (purchasePrice ?? 0) + maintenanceCost;

  Status statusOf(Item it) {
    final last = lastService(it.id);
    if (last == null) {
      return Status(Level.none, t('لم تُسجَّل أي صيانة بعد', "Aucun entretien enregistré"));
    }
    int? remKm;
    int? remDays;
    if (it.intervalKm > 0) {
      remKm = last.km + it.intervalKm - km;
    }
    if (it.intervalMonths > 0) {
      final next = DateTime(
          last.date.year, last.date.month + it.intervalMonths, last.date.day);
      remDays = next.difference(DateTime.now()).inDays;
    }
    if (remKm == null && remDays == null) {
      return Status(Level.ok, t('بدون موعد محدد', "Sans échéance définie"));
    }
    final parts = <String>[];
    if (remKm != null) {
      parts.add(remKm < 0 ? t('تجاوزت ${fmt(-remKm)} كم', "Dépassé de ${fmt(-remKm)} km") : t('باقي ${fmt(remKm)} كم', "Reste ${fmt(remKm)} km"));
    }
    if (remDays != null) {
      parts.add(remDays < 0 ? t('تجاوزت ${-remDays} يوم', "Dépassé de ${-remDays} j") : t('باقي $remDays يوم', "Reste $remDays j"));
    }
    final overdue =
        (remKm != null && remKm < 0) || (remDays != null && remDays < 0);
    final soon = (remKm != null && remKm <= it.intervalKm ~/ 10) ||
        (remDays != null && remDays <= 30);
    final level = overdue ? Level.overdue : (soon ? Level.soon : Level.ok);
    return Status(level, parts.join(' • '));
  }
}

// ====================== التخزين والمنطق ======================

class Store extends ChangeNotifier {
  final SharedPreferences prefs;
  List<Car> cars = [];
  String currentId = '';
  int modifiedAt = 0;

  Store(this.prefs);

  bool get weeklyKm => prefs.getBool('weeklyKm') ?? false;

  void setWeeklyKm(bool v) {
    prefs.setBool('weeklyKm', v);
    notifyListeners();
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  static Future<Store> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = Store(prefs);
    // اللغة: المحفوظة، وإلا لغة الهاتف (الفرنسية إن كانت لغة الهاتف) وإلا العربية
    final saved = prefs.getString('lang');
    if (saved == 'fr' || saved == 'ar') {
      Lang.code = saved!;
    } else {
      final dev = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
      Lang.code = dev == 'fr' ? 'fr' : 'ar';
    }
    final raw = prefs.getString('data');
    if (raw != null) {
      try {
        s._parse(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    if (s.cars.isEmpty) {
      s.cars = [Car(id: newId(), name: t('سيارتي', "Ma voiture"))];
    }
    if (!s.cars.any((c) => c.id == s.currentId)) {
      s.currentId = s.cars.first.id;
    }
    return s;
  }

  void _parse(Map<String, dynamic> j) {
    modifiedAt = (j['modifiedAt'] as num?)?.toInt() ?? 0;
    if (j['cars'] is List) {
      cars = (j['cars'] as List)
          .map((e) => Car.fromJson(e as Map<String, dynamic>))
          .toList();
      currentId = j['currentId'] as String? ?? '';
    } else {
      // بيانات النسخة القديمة (سيارة واحدة): نحوّلها تلقائياً
      final old = Car(
        id: newId(),
        name: j['carName'] as String? ?? t('سيارتي', "Ma voiture"),
        km: (j['currentKm'] as num?)?.toInt() ?? 0,
        items: ((j['items'] as List?) ?? [])
            .map((e) => Item.fromJson(e as Map<String, dynamic>))
            .toList(),
        services: ((j['services'] as List?) ?? [])
            .map((e) => Service.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
      cars = [old];
      currentId = old.id;
    }
  }

  Map<String, dynamic> _toJson() => {
        'cars': cars.map((c) => c.toJson()).toList(),
        'currentId': currentId,
        'modifiedAt': modifiedAt,
      };

  void _save() {
    modifiedAt = DateTime.now().millisecondsSinceEpoch;
    prefs.setString('data', jsonEncode(_toJson()));
    notifyListeners();
  }

  /// يطبّق نسخة قادمة من السحابة (بدون تغيير ختم التعديل)
  void applyRemote(Map<String, dynamic> j) {
    final oldCars = cars;
    final oldId = currentId;
    final oldStamp = modifiedAt;
    try {
      _parse(j);
      if (cars.isEmpty) throw const FormatException('empty');
      if (!cars.any((c) => c.id == currentId)) currentId = cars.first.id;
      prefs.setString('data', jsonEncode(_toJson()));
      notifyListeners();
    } catch (_) {
      cars = oldCars;
      currentId = oldId;
      modifiedAt = oldStamp;
    }
  }

  void setLang(String code) {
    Lang.code = code;
    prefs.setString('lang', code);
    notifyListeners();
  }

  String exportJson() => jsonEncode(_toJson());

  bool importJson(String raw) {
    final oldCars = cars;
    final oldId = currentId;
    try {
      _parse(jsonDecode(raw.trim()) as Map<String, dynamic>);
      if (cars.isEmpty) throw const FormatException('empty');
      if (!cars.any((c) => c.id == currentId)) currentId = cars.first.id;
      _save();
      return true;
    } catch (_) {
      cars = oldCars;
      currentId = oldId;
      return false;
    }
  }

  // ---- السيارة الحالية ----
  Car get car {
    for (final c in cars) {
      if (c.id == currentId) return c;
    }
    return cars.first;
  }

  String get carName => car.label;
  int get currentKm => car.km;
  List<Item> get items => car.items;
  List<Service> get services => car.services;
  Item? itemById(String id) => car.itemById(id);
  Service? lastService(String id) => car.lastService(id);
  Status statusOf(Item it) => car.statusOf(it);

  double get grandTotal => cars.fold<double>(0, (a, c) => a + c.totalCost);

  void selectCar(String id) {
    currentId = id;
    _save();
  }

  Car addCar(String name, int km, double? price) {
    final c = Car(id: newId(), name: name, km: km, purchasePrice: price);
    cars.add(c);
    currentId = c.id;
    _save();
    return c;
  }

  void updateCar(Car c, String name, int km, double? price) {
    c.name = name;
    c.km = km;
    c.purchasePrice = price;
    _save();
  }

  void deleteCar(Car c) {
    if (cars.length <= 1) return;
    cars.remove(c);
    if (currentId == c.id) currentId = cars.first.id;
    _save();
  }

  // ---- بنود وصيانات السيارة الحالية ----
  void addItem(Item i) {
    car.items.add(i);
    _save();
  }

  void updateItem() => _save();

  void deleteItem(String id) {
    car.items.removeWhere((e) => e.id == id);
    car.services.removeWhere((s) => s.itemId == id);
    _save();
  }

  void addService(Service s) {
    car.services.add(s);
    if (s.km > car.km) car.km = s.km;
    _save();
  }

  void deleteService(Service s) {
    car.services.remove(s);
    _save();
  }

  void addFuel(FuelEntry e) {
    car.fuel.add(e);
    if (e.km > car.km) car.km = e.km;
    _save();
  }

  void addDoc(CarDoc d) {
    car.docs.add(d);
    _save();
  }

  void deleteDoc(CarDoc d) {
    car.docs.remove(d);
    _save();
  }

  void deleteFuel(FuelEntry e) {
    car.fuel.remove(e);
    _save();
  }
}

// ====================== التطبيق ======================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.load();
  cloud = Cloud(store);
  runApp(CarApp(store: store));
  if (cloud.loggedIn) cloud.syncNow();
  pingInstall(store);
  // التنبيهات تبدأ بعد عرض التطبيق (طلب الإذن لا يؤخر الفتح)
  Notifier.init().then((_) {
    Notifier.sync(store);
    store.addListener(() => Notifier.sync(store));
  });
}

class CarApp extends StatelessWidget {
  final Store store;
  const CarApp({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        title: t('صيانة سيارتي', "Entretien auto"),
        debugShowCheckedModeBanner: false,
        locale: Locale(Lang.code),
        supportedLocales: const [Locale('ar'), Locale('fr')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          useMaterial3: true,
        ),
        home: HomePage(store: store),
      ),
    );
  }
}

Widget sumRow(String label, String value, {bool bold = false}) {
  final style = TextStyle(
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    fontSize: bold ? 17 : 15,
  );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label, style: style), Text(value, style: style)],
    ),
  );
}

class HomePage extends StatefulWidget {
  final Store store;
  const HomePage({super.key, required this.store});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _menu(String v) async {
    final store = widget.store;
    switch (v) {
      case 'report':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ReportPage(store: store)),
        );
        break;
      case 'fuel':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => FuelPage(store: store)),
        );
        break;
      case 'docs':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => DocsPage(store: store)),
        );
        break;
      case 'charts':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChartsPage(store: store)),
        );
        break;
      case 'share':
        await shareApp(context);
        break;
      case 'backupFile':
        await shareBackupFile(context, store);
        break;
      case 'restoreFile':
        await restoreBackupFile(context, store);
        break;
      case 'cloud':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CloudPage()),
        );
        break;
      case 'nearby':
        nearbyDialog(context);
        break;
      case 'weekly':
        store.setWeeklyKm(!store.weeklyKm);
        _snack(store.weeklyKm
            ? t('سيذكّرك التطبيق كل أحد بتحديث العداد', "Un rappel chaque dimanche pour mettre à jour le compteur")
            : t('أُلغي التذكير الأسبوعي', "Rappel hebdomadaire désactivé"));
        break;
      case 'backup':
        await Clipboard.setData(ClipboardData(text: store.exportJson()));
        _snack(t('تم نسخ كل بياناتك. الصقها في ملاحظات أو أرسلها لنفسك للحفظ', "Toutes vos données ont été copiées. Collez-les dans une note ou envoyez-les-vous pour les conserver"));
        break;
      case 'restore':
        _restoreDialog();
        break;
      case 'lang':
        _langDialog();
        break;
      case 'about':
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: GestureDetector(
              onLongPress: () {
                Navigator.pop(ctx);
                adminEntry(context, store);
              },
              child: Text(t('حول التطبيق', "À propos")),
            ),
            content: Text(t('صيانة سيارتي - الإصدار $appVersion\n\nيرسل التطبيق مرة في اليوم رقماً عشوائياً مجهولاً مع رقم الإصدار واللغة فقط، لنعرف عدد المستعملين. لا يُرسل أي اسم أو بيانات سيارة أو موقع.', "Mon entretien auto - version $appVersion\n\nUne fois par jour, l'application envoie un numéro aléatoire anonyme avec la version et la langue, uniquement pour compter les utilisateurs. Aucun nom, donnée de voiture ou position n'est envoyé.")),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
        break;
      case 'test':
        final ok = await Notifier.test();
        _snack(ok
            ? t('أُرسل إشعار تجريبي', "Notification de test envoyée")
            : t('التنبيهات غير مفعّلة: فعّلها من إعدادات الهاتف للتطبيق', "Notifications désactivées : activez-les dans les paramètres du téléphone pour l'application"));
        break;
    }
  }

  void _langDialog() {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('اللغة / Langue'),
        children: [
          ListTile(
            title: const Text('العربية'),
            trailing: Lang.code == 'ar' ? const Icon(Icons.check) : null,
            onTap: () {
              widget.store.setLang('ar');
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            title: const Text('Français'),
            trailing: Lang.code == 'fr' ? const Icon(Icons.check) : null,
            onTap: () {
              widget.store.setLang('fr');
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  void _restoreDialog() {
    final ctl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('استعادة من نسخة احتياطية', "Restaurer une sauvegarde")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('الصق النص المنسوخ سابقاً. سيتم استبدال البيانات الحالية.', "Collez le texte copié précédemment. Les données actuelles seront remplacées.")),
            const SizedBox(height: 8),
            TextField(
              controller: ctl,
              maxLines: 5,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t('إلغاء', "Annuler"))),
          FilledButton(
            onPressed: () {
              final ok = widget.store.importJson(ctl.text);
              Navigator.pop(ctx);
              _snack(ok ? t('تمت الاستعادة بنجاح', "Restauration réussie") : t('النص غير صالح', "Texte invalide"));
            },
            child: Text(t('استعادة', "Restaurer")),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(tab == 0 ? store.carName : t('سجل ${store.carName}', "Historique ${store.carName}")),
            actions: [
              IconButton(
                tooltip: t('تقرير PDF', "Rapport PDF"),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: () => _menu('report'),
              ),
              PopupMenuButton<String>(
                onSelected: _menu,
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'docs', child: Text(t('وثائق السيارة', "Documents de la voiture"))),
                  PopupMenuItem(value: 'charts', child: Text(t('رسوم بيانية', "Graphiques"))),
                  PopupMenuItem(value: 'fuel', child: Text(t('سجل الوقود', "Carburant"))),
                  PopupMenuItem(value: 'nearby', child: Text(t('ورشة / محطة قريبة', "Garage / station proche"))),
                  PopupMenuItem(value: 'cloud', child: Text(t('حسابي والمزامنة', "Mon compte et synchro"))),
                  PopupMenuItem(
                      value: 'weekly',
                      child: Text(store.weeklyKm
                          ? t('✓ تذكير تحديث العداد (أسبوعي)', "✓ Rappel compteur (hebdo)")
                          : t('تذكير تحديث العداد (أسبوعي)', "Rappel compteur (hebdo)"))),
                  const PopupMenuItem(value: 'lang', child: Text('اللغة / Langue')),
                  PopupMenuItem(value: 'share', child: Text(t('شارك التطبيق مع أصدقائك', "Partager l'application"))),
                  PopupMenuItem(value: 'about', child: Text(t('حول التطبيق', "À propos"))),
                  PopupMenuItem(value: 'backupFile', child: Text(t('نسخة احتياطية كملف (مشاركة)', "Sauvegarde en fichier (partager)"))),
                  PopupMenuItem(value: 'restoreFile', child: Text(t('استعادة من ملف', "Restaurer depuis un fichier"))),
                  PopupMenuItem(value: 'backup', child: Text(t('نسخ احتياطي (نسخ البيانات)', "Sauvegarde (copier les données)"))),
                  PopupMenuItem(value: 'restore', child: Text(t('استعادة من نسخة', "Restaurer une sauvegarde"))),
                  PopupMenuItem(value: 'test', child: Text(t('تجربة التنبيه', "Tester la notification"))),
                ],
              ),
            ],
          ),
          body: tab == 0 ? _itemsTab(context) : _historyTab(context),
          floatingActionButton: tab == 0
              ? FloatingActionButton.extended(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => ItemDialog(store: store),
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(t('إضافة بند', "Ajouter un élément")),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: [
              NavigationDestination(icon: Icon(Icons.build), label: t('الصيانات', "Entretiens")),
              NavigationDestination(icon: Icon(Icons.history), label: t('السجل', "Historique")),
            ],
          ),
        );
      },
    );
  }

  Widget _itemsTab(BuildContext context) {
    final store = widget.store;
    final car = store.car;
    final entries = store.items
        .map((it) => MapEntry(it, store.statusOf(it)))
        .toList()
      ..sort((a, b) => a.value.level.index.compareTo(b.value.level.index));

    final sub = StringBuffer(t('العداد: ${fmt(car.km)} كم', "Compteur : ${fmt(car.km)} km"));
    if (car.purchasePrice != null) {
      sub.write(t('\nثمن الشراء: ${fmtMoney(car.purchasePrice!)}', "\nPrix d'achat : ${fmtMoney(car.purchasePrice!)}"));
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.directions_car, size: 36),
            title: Text(car.label,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(sub.toString()),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: t('السيارات', "Voitures"),
                  icon: const Icon(Icons.swap_horiz),
                  onPressed: () => showCars(context, store),
                ),
                IconButton(
                  tooltip: t('تعديل السيارة', "Modifier la voiture"),
                  icon: const Icon(Icons.edit),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => CarDialog(store: store, car: car),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        for (final e in entries)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: e.value.color.withOpacity(0.15),
                child: Icon(iconFor(e.key.id), color: e.value.color),
              ),
              title: Text(e.key.label),
              subtitle:
                  Text(e.value.text, style: TextStyle(color: e.value.color)),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ItemPage(store: store, itemId: e.key.id),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _historyTab(BuildContext context) {
    final store = widget.store;
    final car = store.car;
    final list = [...store.services]..sort((a, b) => b.date.compareTo(a.date));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                if (car.purchasePrice != null)
                  sumRow(t('ثمن الشراء', "Prix d'achat"), fmtMoney(car.purchasePrice!)),
                sumRow(t('مصاريف الصيانة', "Frais d'entretien"), fmtMoney(car.maintenanceCost)),
                const Divider(),
                sumRow(t('المجموع الكلي', "Total général"), fmtMoney(car.totalCost), bold: true),
                if (store.cars.length > 1) ...[
                  const SizedBox(height: 6),
                  sumRow(t('مجموع كل السيارات', "Total de toutes les voitures"), fmtMoney(store.grandTotal)),
                ],
              ],
            ),
          ),
        ),
        if (list.isEmpty)
          Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text(t('لا توجد صيانات مسجلة بعد', "Aucun entretien enregistré"))),
          ),
        for (final s in list) _serviceTile(context, store, s),
      ],
    );
  }
}

Widget _serviceTile(BuildContext context, Store store, Service s) {
  final item = store.itemById(s.itemId);
  final sub = StringBuffer(t('${fmtDate(s.date)} • ${fmt(s.km)} كم', "${fmtDate(s.date)} • ${fmt(s.km)} km"));
  if (s.note.isNotEmpty) sub.write(' • ${s.note}');
  return Card(
    child: ListTile(
      leading: Icon(iconFor(s.itemId)),
      title: Text(item?.label ?? t('بند محذوف', "Élément supprimé")),
      subtitle: Text(sub.toString()),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s.cost > 0) Text(fmtMoney(s.cost)),
          if (s.photo != null)
            IconButton(
              tooltip: t('الفاتورة', "Facture"),
              icon: const Icon(Icons.receipt_long),
              onPressed: () => showPhoto(context, s.photo!),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(context, t('حذف هذا التسجيل؟', "Supprimer cet enregistrement ?"))) {
                store.deleteService(s);
              }
            },
          ),
        ],
      ),
    ),
  );
}

// ====================== قائمة السيارات ======================

void showCars(BuildContext context, Store store) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => ListenableBuilder(
      listenable: store,
      builder: (ctx, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t('سياراتي', "Mes voitures"), style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in store.cars)
                      ListTile(
                        leading: Icon(c.id == store.currentId
                            ? Icons.check_circle
                            : Icons.circle_outlined),
                        title: Text(c.label),
                        subtitle: Text(t('${fmt(c.km)} كم', "${fmt(c.km)} km")),
                        trailing: IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () => showDialog(
                            context: ctx,
                            builder: (_) => CarDialog(store: store, car: c),
                          ),
                        ),
                        onTap: () {
                          store.selectCar(c.id);
                          Navigator.pop(ctx);
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () async {
                  await showDialog(
                    context: ctx,
                    builder: (_) => CarDialog(store: store),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.add),
                label: Text(t('إضافة سيارة', "Ajouter une voiture")),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ====================== صفحة البند ======================

class ItemPage extends StatelessWidget {
  final Store store;
  final String itemId;
  const ItemPage({super.key, required this.store, required this.itemId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final it = store.itemById(itemId);
        if (it == null) return const Scaffold(body: SizedBox());
        final st = store.statusOf(it);
        final last = store.lastService(it.id);
        final hist = store.services.where((s) => s.itemId == it.id).toList()
          ..sort((a, b) => b.date.compareTo(a.date));
        final intervals = <String>[];
        if (it.intervalKm > 0) intervals.add(t('كل ${fmt(it.intervalKm)} كم', "Tous les ${fmt(it.intervalKm)} km"));
        if (it.intervalMonths > 0) intervals.add(t('كل ${it.intervalMonths} شهر', "Tous les ${it.intervalMonths} mois"));

        return Scaffold(
          appBar: AppBar(
            title: Text(it.label),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => ItemDialog(store: store, item: it),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (await confirm(context, t('حذف هذا البند وكل سجلاته؟', "Supprimer cet élément et tout son historique ?"))) {
                    store.deleteItem(it.id);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        st.text,
                        style: TextStyle(
                            color: st.color,
                            fontWeight: FontWeight.bold,
                            fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Text(
                          t('الفاصل: ${intervals.isEmpty ? 'غير محدد' : intervals.join(' أو ')}', "Intervalle : ${intervals.isEmpty ? 'non défini' : intervals.join(' ou ')}")),
                      if (store.car.predictedDate(it) != null)
                        Text(
                            t('التاريخ المتوقع (حسب استعمالك): ${fmtDate(store.car.predictedDate(it)!)}', "Date prévue (selon votre usage) : ${fmtDate(store.car.predictedDate(it)!)}")),
                      if (last != null)
                        Text(
                            t('آخر صيانة: ${fmtDate(last.date)} • ${fmt(last.km)} كم', "Dernier entretien : ${fmtDate(last.date)} • ${fmt(last.km)} km")),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ServiceForm(store: store, item: it),
                ),
                icon: const Icon(Icons.add_task),
                label: Text(t('سجّل صيانة جديدة', "Enregistrer un entretien")),
              ),
              if (last != null && it.intervalMonths > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    onPressed: () => addToCalendar(
                      context,
                      t('صيانة: ${it.label} (${store.carName})', "Entretien : ${it.label} (${store.carName})"),
                      DateTime(last.date.year, last.date.month + it.intervalMonths, last.date.day),
                    ),
                    icon: const Icon(Icons.event_available),
                    label: Text(t('أضف الموعد القادم إلى التقويم', "Ajouter la prochaine échéance à l'agenda")),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: () => nearbyDialog(context),
                  icon: const Icon(Icons.place_outlined),
                  label: Text(t('ورشة أو محل قريب', "Garage ou magasin proche")),
                ),
              ),
              const SizedBox(height: 16),
              Text(t('السجل', "Historique"),
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              if (hist.isEmpty) Text(t('لا يوجد تسجيل بعد', "Aucun enregistrement")),
              for (final s in hist) _serviceTile(context, store, s),
            ],
          ),
        );
      },
    );
  }
}

// ====================== النماذج (Forms) ======================

class ServiceForm extends StatefulWidget {
  final Store store;
  final Item item;
  const ServiceForm({super.key, required this.store, required this.item});

  @override
  State<ServiceForm> createState() => _ServiceFormState();
}

class _ServiceFormState extends State<ServiceForm> {
  late final TextEditingController km =
      TextEditingController(text: widget.store.currentKm.toString());
  final TextEditingController cost = TextEditingController();
  final TextEditingController note = TextEditingController();
  DateTime date = DateTime.now();
  String? error;
  String? photo;

  @override
  void dispose() {
    km.dispose();
    cost.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final d = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) setState(() => date = d);
  }

  void _save() {
    final k = parseInt(km.text.trim());
    if (k == null || k < 0) {
      setState(() => error = t('أدخل العداد بأرقام صحيحة', "Saisissez un kilométrage valide"));
      return;
    }
    final c = cost.text.trim().isEmpty ? 0.0 : parseDouble(cost.text.trim());
    if (c == null || c < 0) {
      setState(() => error = t('السعر غير صحيح', "Prix invalide"));
      return;
    }
    widget.store.addService(Service(
      itemId: widget.item.id,
      date: date,
      km: k,
      cost: c,
      note: note.text.trim(),
      photo: photo,
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('تسجيل: ${widget.item.label}', "Enregistrement : ${widget.item.label}"),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.event),
              label: Text(t('التاريخ: ${fmtDate(date)}', "Date : ${fmtDate(date)}")),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: km,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: t('العداد (كم)', "Compteur (km)"), border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cost,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t('السعر (دج) - اختياري', "Prix (DA) - facultatif"),
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              decoration: InputDecoration(
                  labelText: t('ملاحظة - اختياري', "Remarque - facultatif"), border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final p = await pickInvoicePhoto(context);
                      if (p != null && mounted) setState(() => photo = p);
                    },
                    icon: Icon(photo == null ? Icons.add_a_photo : Icons.check_circle),
                    label: Text(photo == null
                        ? t('صورة الفاتورة - اختياري', "Photo de la facture - facultatif")
                        : t('تمت إضافة الصورة (اضغط للتغيير)', "Photo ajoutée (toucher pour changer)")),
                  ),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: Text(t('حفظ', "Enregistrer"))),
          ],
        ),
      ),
    );
  }
}

class ItemDialog extends StatefulWidget {
  final Store store;
  final Item? item;
  const ItemDialog({super.key, required this.store, this.item});

  @override
  State<ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<ItemDialog> {
  late final TextEditingController name =
      TextEditingController(text: widget.item?.label ?? '');
  late final TextEditingController km = TextEditingController(
      text: widget.item == null ? '' : widget.item!.intervalKm.toString());
  late final TextEditingController months = TextEditingController(
      text: widget.item == null ? '' : widget.item!.intervalMonths.toString());
  String? error;

  @override
  void dispose() {
    name.dispose();
    km.dispose();
    months.dispose();
    super.dispose();
  }

  void _save() {
    final n = name.text.trim();
    final k = km.text.trim().isEmpty ? 0 : parseInt(km.text.trim());
    final m = months.text.trim().isEmpty ? 0 : parseInt(months.text.trim());
    if (n.isEmpty) {
      setState(() => error = t('أدخل اسم البند', "Saisissez le nom de l'élément"));
      return;
    }
    if (k == null || m == null || k < 0 || m < 0) {
      setState(() => error = t('أدخل أرقاماً صحيحة', "Saisissez des nombres valides"));
      return;
    }
    if (k == 0 && m == 0) {
      setState(() => error = t('حدّد فاصلاً بالكيلومتر أو بالأشهر', "Définissez un intervalle en km ou en mois"));
      return;
    }
    final it = widget.item;
    if (it == null) {
      widget.store.addItem(Item(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: n,
        intervalKm: k,
        intervalMonths: m,
      ));
    } else {
      it.name = n;
      it.intervalKm = k;
      it.intervalMonths = m;
      widget.store.updateItem();
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? t('بند جديد', "Nouvel élément") : t('تعديل البند', "Modifier l'élément")),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: InputDecoration(labelText: t('الاسم', "Nom")),
            ),
            TextField(
              controller: km,
              keyboardType: TextInputType.number,
              decoration:
                  InputDecoration(labelText: t('كل كم كيلومتر (0 = بدون)', "Tous les combien de km (0 = aucun)")),
            ),
            TextField(
              controller: months,
              keyboardType: TextInputType.number,
              decoration:
                  InputDecoration(labelText: t('كل كم شهر (0 = بدون)', "Tous les combien de mois (0 = aucun)")),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('إلغاء', "Annuler"))),
        FilledButton(onPressed: _save, child: Text(t('حفظ', "Enregistrer"))),
      ],
    );
  }
}

/// إضافة سيارة جديدة (car == null) أو تعديل سيارة موجودة
class CarDialog extends StatefulWidget {
  final Store store;
  final Car? car;
  const CarDialog({super.key, required this.store, this.car});

  @override
  State<CarDialog> createState() => _CarDialogState();
}

class _CarDialogState extends State<CarDialog> {
  late final TextEditingController name = TextEditingController(
      text: widget.car?.label ?? t('سيارة ${widget.store.cars.length + 1}', "Voiture ${widget.store.cars.length + 1}"));
  late final TextEditingController km =
      TextEditingController(text: (widget.car?.km ?? 0).toString());
  late final TextEditingController price = TextEditingController(
      text: widget.car?.purchasePrice == null
          ? ''
          : numText(widget.car!.purchasePrice!));
  String? error;

  @override
  void dispose() {
    name.dispose();
    km.dispose();
    price.dispose();
    super.dispose();
  }

  void _save() {
    final k = parseInt(km.text.trim());
    if (k == null || k < 0) {
      setState(() => error = t('أدخل العداد بأرقام صحيحة', "Saisissez un kilométrage valide"));
      return;
    }
    double? p;
    if (price.text.trim().isNotEmpty) {
      p = parseDouble(price.text.trim());
      if (p == null || p < 0) {
        setState(() => error = t('سعر الشراء غير صحيح', "Prix d'achat invalide"));
        return;
      }
    }
    final n = name.text.trim().isEmpty ? t('سيارتي', "Ma voiture") : name.text.trim();
    final c = widget.car;
    if (c == null) {
      widget.store.addCar(n, k, p);
    } else {
      widget.store.updateCar(c, n, k, p);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.car;
    return AlertDialog(
      title: Text(c == null ? t('سيارة جديدة', "Nouvelle voiture") : t('بيانات السيارة', "Données de la voiture")),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: InputDecoration(
                  labelText: t('اسم السيارة (مثال: كليو 2018)', "Nom de la voiture (ex. : Clio 2018)")),
            ),
            TextField(
              controller: km,
              keyboardType: TextInputType.number,
              decoration:
                  InputDecoration(labelText: t('العداد الحالي (كم)', "Compteur actuel (km)")),
            ),
            TextField(
              controller: price,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t('ثمن الشراء (دج) - اختياري', "Prix d'achat (DA) - facultatif")),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
      actions: [
        if (c != null && widget.store.cars.length > 1)
          TextButton(
            onPressed: () async {
              if (await confirm(
                  context, t('حذف هذه السيارة وكل صيانتها نهائياً؟', "Supprimer définitivement cette voiture et tout son entretien ?"))) {
                widget.store.deleteCar(c);
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: Text(t('حذف', "Supprimer"), style: TextStyle(color: Colors.red)),
          ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('إلغاء', "Annuler"))),
        FilledButton(onPressed: _save, child: Text(t('حفظ', "Enregistrer"))),
      ],
    );
  }
}

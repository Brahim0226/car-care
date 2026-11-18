import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifications.dart';
import 'report.dart';

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

String fmtMoney(double v) => '${fmt(v.round())} دج';

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
            child: const Text('إلغاء')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تأكيد')),
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

  Service({
    required this.itemId,
    required this.date,
    required this.km,
    required this.cost,
    required this.note,
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'date': date.toIso8601String(),
        'km': km,
        'cost': cost,
        'note': note,
      };

  factory Service.fromJson(Map<String, dynamic> j) => Service(
        itemId: j['itemId'] as String,
        date: DateTime.parse(j['date'] as String),
        km: (j['km'] as num).toInt(),
        cost: (j['cost'] as num).toDouble(),
        note: j['note'] as String? ?? '',
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

  Car({
    required this.id,
    required this.name,
    this.km = 0,
    this.purchasePrice,
    List<Item>? items,
    List<Service>? services,
  })  : items = items ?? defaultItems(),
        services = services ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'km': km,
        'purchasePrice': purchasePrice,
        'items': items.map((e) => e.toJson()).toList(),
        'services': services.map((e) => e.toJson()).toList(),
      };

  factory Car.fromJson(Map<String, dynamic> j) => Car(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'سيارتي',
        km: (j['km'] as num?)?.toInt() ?? 0,
        purchasePrice: (j['purchasePrice'] as num?)?.toDouble(),
        items: ((j['items'] as List?) ?? [])
            .map((e) => Item.fromJson(e as Map<String, dynamic>))
            .toList(),
        services: ((j['services'] as List?) ?? [])
            .map((e) => Service.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

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
      return const Status(Level.none, 'لم تُسجَّل أي صيانة بعد');
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
      return const Status(Level.ok, 'بدون موعد محدد');
    }
    final parts = <String>[];
    if (remKm != null) {
      parts.add(remKm < 0 ? 'تجاوزت ${fmt(-remKm)} كم' : 'باقي ${fmt(remKm)} كم');
    }
    if (remDays != null) {
      parts.add(remDays < 0 ? 'تجاوزت ${-remDays} يوم' : 'باقي $remDays يوم');
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

  Store(this.prefs);

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  static Future<Store> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = Store(prefs);
    final raw = prefs.getString('data');
    if (raw != null) {
      try {
        s._parse(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    if (s.cars.isEmpty) {
      s.cars = [Car(id: newId(), name: 'سيارتي')];
    }
    if (!s.cars.any((c) => c.id == s.currentId)) {
      s.currentId = s.cars.first.id;
    }
    return s;
  }

  void _parse(Map<String, dynamic> j) {
    if (j['cars'] is List) {
      cars = (j['cars'] as List)
          .map((e) => Car.fromJson(e as Map<String, dynamic>))
          .toList();
      currentId = j['currentId'] as String? ?? '';
    } else {
      // بيانات النسخة القديمة (سيارة واحدة): نحوّلها تلقائياً
      final old = Car(
        id: newId(),
        name: j['carName'] as String? ?? 'سيارتي',
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
      };

  void _save() {
    prefs.setString('data', jsonEncode(_toJson()));
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

  String get carName => car.name;
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
}

// ====================== التطبيق ======================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.load();
  runApp(CarApp(store: store));
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
    return MaterialApp(
      title: 'صيانة سيارتي',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        useMaterial3: true,
      ),
      home: HomePage(store: store),
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
      case 'backup':
        await Clipboard.setData(ClipboardData(text: store.exportJson()));
        _snack('تم نسخ كل بياناتك. الصقها في ملاحظات أو أرسلها لنفسك للحفظ');
        break;
      case 'restore':
        _restoreDialog();
        break;
      case 'test':
        final ok = await Notifier.test();
        _snack(ok
            ? 'أُرسل إشعار تجريبي'
            : 'التنبيهات غير مفعّلة: فعّلها من إعدادات الهاتف للتطبيق');
        break;
    }
  }

  void _restoreDialog() {
    final ctl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('استعادة من نسخة احتياطية'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('الصق النص المنسوخ سابقاً. سيتم استبدال البيانات الحالية.'),
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
              onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final ok = widget.store.importJson(ctl.text);
              Navigator.pop(ctx);
              _snack(ok ? 'تمت الاستعادة بنجاح' : 'النص غير صالح');
            },
            child: const Text('استعادة'),
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
            title: Text(tab == 0 ? store.carName : 'سجل ${store.carName}'),
            actions: [
              IconButton(
                tooltip: 'تقرير PDF',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: () => _menu('report'),
              ),
              PopupMenuButton<String>(
                onSelected: _menu,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'backup', child: Text('نسخ احتياطي (نسخ البيانات)')),
                  PopupMenuItem(value: 'restore', child: Text('استعادة من نسخة')),
                  PopupMenuItem(value: 'test', child: Text('تجربة التنبيه')),
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
                  label: const Text('إضافة بند'),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.build), label: 'الصيانات'),
              NavigationDestination(icon: Icon(Icons.history), label: 'السجل'),
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

    final sub = StringBuffer('العداد: ${fmt(car.km)} كم');
    if (car.purchasePrice != null) {
      sub.write('\nثمن الشراء: ${fmtMoney(car.purchasePrice!)}');
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.directions_car, size: 36),
            title: Text(car.name,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(sub.toString()),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'السيارات',
                  icon: const Icon(Icons.swap_horiz),
                  onPressed: () => showCars(context, store),
                ),
                IconButton(
                  tooltip: 'تعديل السيارة',
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
              title: Text(e.key.name),
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
                  sumRow('ثمن الشراء', fmtMoney(car.purchasePrice!)),
                sumRow('مصاريف الصيانة', fmtMoney(car.maintenanceCost)),
                const Divider(),
                sumRow('المجموع الكلي', fmtMoney(car.totalCost), bold: true),
                if (store.cars.length > 1) ...[
                  const SizedBox(height: 6),
                  sumRow('مجموع كل السيارات', fmtMoney(store.grandTotal)),
                ],
              ],
            ),
          ),
        ),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('لا توجد صيانات مسجلة بعد')),
          ),
        for (final s in list) _serviceTile(context, store, s),
      ],
    );
  }
}

Widget _serviceTile(BuildContext context, Store store, Service s) {
  final item = store.itemById(s.itemId);
  final sub = StringBuffer('${fmtDate(s.date)} • ${fmt(s.km)} كم');
  if (s.note.isNotEmpty) sub.write(' • ${s.note}');
  return Card(
    child: ListTile(
      leading: Icon(iconFor(s.itemId)),
      title: Text(item?.name ?? 'بند محذوف'),
      subtitle: Text(sub.toString()),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s.cost > 0) Text(fmtMoney(s.cost)),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(context, 'حذف هذا التسجيل؟')) {
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
              Text('سياراتي', style: Theme.of(ctx).textTheme.titleMedium),
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
                        title: Text(c.name),
                        subtitle: Text('${fmt(c.km)} كم'),
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
                label: const Text('إضافة سيارة'),
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
        if (it.intervalKm > 0) intervals.add('كل ${fmt(it.intervalKm)} كم');
        if (it.intervalMonths > 0) intervals.add('كل ${it.intervalMonths} شهر');

        return Scaffold(
          appBar: AppBar(
            title: Text(it.name),
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
                  if (await confirm(context, 'حذف هذا البند وكل سجلاته؟')) {
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
                          'الفاصل: ${intervals.isEmpty ? 'غير محدد' : intervals.join(' أو ')}'),
                      if (last != null)
                        Text(
                            'آخر صيانة: ${fmtDate(last.date)} • ${fmt(last.km)} كم'),
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
                label: const Text('سجّل صيانة جديدة'),
              ),
              const SizedBox(height: 16),
              const Text('السجل',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              if (hist.isEmpty) const Text('لا يوجد تسجيل بعد'),
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
      setState(() => error = 'أدخل العداد بأرقام صحيحة');
      return;
    }
    final c = cost.text.trim().isEmpty ? 0.0 : parseDouble(cost.text.trim());
    if (c == null || c < 0) {
      setState(() => error = 'السعر غير صحيح');
      return;
    }
    widget.store.addService(Service(
      itemId: widget.item.id,
      date: date,
      km: k,
      cost: c,
      note: note.text.trim(),
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
            Text('تسجيل: ${widget.item.name}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.event),
              label: Text('التاريخ: ${fmtDate(date)}'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: km,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'العداد (كم)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cost,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'السعر (دج) - اختياري',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              decoration: const InputDecoration(
                  labelText: 'ملاحظة - اختياري', border: OutlineInputBorder()),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('حفظ')),
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
      TextEditingController(text: widget.item?.name ?? '');
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
      setState(() => error = 'أدخل اسم البند');
      return;
    }
    if (k == null || m == null || k < 0 || m < 0) {
      setState(() => error = 'أدخل أرقاماً صحيحة');
      return;
    }
    if (k == 0 && m == 0) {
      setState(() => error = 'حدّد فاصلاً بالكيلومتر أو بالأشهر');
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
      title: Text(widget.item == null ? 'بند جديد' : 'تعديل البند'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'الاسم'),
            ),
            TextField(
              controller: km,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'كل كم كيلومتر (0 = بدون)'),
            ),
            TextField(
              controller: months,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'كل كم شهر (0 = بدون)'),
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
            child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
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
      text: widget.car?.name ?? 'سيارة ${widget.store.cars.length + 1}');
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
      setState(() => error = 'أدخل العداد بأرقام صحيحة');
      return;
    }
    double? p;
    if (price.text.trim().isNotEmpty) {
      p = parseDouble(price.text.trim());
      if (p == null || p < 0) {
        setState(() => error = 'سعر الشراء غير صحيح');
        return;
      }
    }
    final n = name.text.trim().isEmpty ? 'سيارتي' : name.text.trim();
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
      title: Text(c == null ? 'سيارة جديدة' : 'بيانات السيارة'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(
                  labelText: 'اسم السيارة (مثال: كليو 2018)'),
            ),
            TextField(
              controller: km,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'العداد الحالي (كم)'),
            ),
            TextField(
              controller: price,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'ثمن الشراء (دج) - اختياري'),
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
                  context, 'حذف هذه السيارة وكل صيانتها نهائياً؟')) {
                widget.store.deleteCar(c);
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('حذف', style: TextStyle(color: Colors.red)),
          ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

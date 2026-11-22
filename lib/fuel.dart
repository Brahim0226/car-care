import 'package:flutter/material.dart';

import 'extras.dart';
import 'l10n.dart';
import 'main.dart';

/// تعبئة وقود (نفترض أن كل تعبئة تملأ الخزان)
class FuelEntry {
  final String id;
  final DateTime date;
  final int km;
  final double liters;
  final double cost;

  FuelEntry({
    required this.id,
    required this.date,
    required this.km,
    required this.liters,
    required this.cost,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'km': km,
        'liters': liters,
        'cost': cost,
      };

  factory FuelEntry.fromJson(Map<String, dynamic> j) => FuelEntry(
        id: j['id'] as String,
        date: DateTime.parse(j['date'] as String),
        km: (j['km'] as num).toInt(),
        liters: (j['liters'] as num).toDouble(),
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
      );
}

class FuelStats {
  final double? avgPer100;
  final double totalCost;
  final double totalLiters;
  final double? costPerKm;
  const FuelStats(this.avgPer100, this.totalCost, this.totalLiters, this.costPerKm);
}

FuelStats computeFuel(List<FuelEntry> list) {
  final s = [...list]..sort((a, b) => a.km.compareTo(b.km));
  var cost = 0.0;
  var liters = 0.0;
  for (final e in s) {
    cost += e.cost;
    liters += e.liters;
  }
  if (s.length < 2) return FuelStats(null, cost, liters, null);
  final dist = s.last.km - s.first.km;
  if (dist <= 0) return FuelStats(null, cost, liters, null);
  // الاستهلاك: لترات كل التعبئات ما عدا الأولى ÷ المسافة
  var l2 = 0.0;
  var c2 = 0.0;
  for (var i = 1; i < s.length; i++) {
    l2 += s[i].liters;
    c2 += s[i].cost;
  }
  return FuelStats(l2 / dist * 100, cost, liters, c2 / dist);
}

String _d1(double v) {
  final r = (v * 10).round() / 10;
  return r == r.roundToDouble() ? r.round().toString() : r.toString();
}

class FuelPage extends StatelessWidget {
  final Store store;
  const FuelPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final car = store.car;
        final list = [...car.fuel]..sort((a, b) => b.km.compareTo(a.km));
        final st = computeFuel(car.fuel);
        return Scaffold(
          appBar: AppBar(
            title: Text(t('الوقود: ${car.label}', "Carburant : ${car.label}")),
            actions: [
              IconButton(
                tooltip: t('محطة وقود قريبة', "Station proche"),
                icon: const Icon(Icons.local_gas_station),
                onPressed: () => searchNearby(context, t('محطة وقود', 'station-service')),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => FuelForm(store: store),
            ),
            icon: const Icon(Icons.add),
            label: Text(t('تعبئة جديدة', "Nouveau plein")),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            children: [
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      sumRow(
                          t('متوسط الاستهلاك', "Consommation moyenne"),
                          st.avgPer100 == null
                              ? t('أضف تعبئتين على الأقل', "Ajoutez 2 pleins minimum")
                              : t('${_d1(st.avgPer100!)} ل/100كم', "${_d1(st.avgPer100!)} L/100 km"),
                          bold: true),
                      if (st.costPerKm != null)
                        sumRow(t('تكلفة الكيلومتر', "Coût au km"),
                            t('${_d1(st.costPerKm!)} دج', "${_d1(st.costPerKm!)} DA")),
                      sumRow(t('مجموع اللترات', "Total litres"), _d1(st.totalLiters)),
                      const Divider(),
                      sumRow(t('مجموع مصاريف الوقود', "Total carburant"), fmtMoney(st.totalCost)),
                    ],
                  ),
                ),
              ),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                      child: Text(t('لا توجد تعبئات مسجلة بعد', "Aucun plein enregistré"))),
                ),
              for (final e in list)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.local_gas_station),
                    title: Text(t('${_d1(e.liters)} لتر • ${fmtMoney(e.cost)}',
                        "${_d1(e.liters)} L • ${fmtMoney(e.cost)}")),
                    subtitle: Text(t('${fmtDate(e.date)} • ${fmt(e.km)} كم',
                        "${fmtDate(e.date)} • ${fmt(e.km)} km")),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (await confirm(context, t('حذف هذه التعبئة؟', "Supprimer ce plein ?"))) {
                          store.deleteFuel(e);
                        }
                      },
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class FuelForm extends StatefulWidget {
  final Store store;
  const FuelForm({super.key, required this.store});

  @override
  State<FuelForm> createState() => _FuelFormState();
}

class _FuelFormState extends State<FuelForm> {
  late final TextEditingController km =
      TextEditingController(text: widget.store.currentKm.toString());
  final TextEditingController liters = TextEditingController();
  final TextEditingController cost = TextEditingController();
  DateTime date = DateTime.now();
  String? error;

  @override
  void dispose() {
    km.dispose();
    liters.dispose();
    cost.dispose();
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
    final l = parseDouble(liters.text.trim());
    final c = cost.text.trim().isEmpty ? 0.0 : parseDouble(cost.text.trim());
    if (k == null || k < 0) {
      setState(() => error = t('أدخل العداد بأرقام صحيحة', "Saisissez un kilométrage valide"));
      return;
    }
    if (l == null || l <= 0) {
      setState(() => error = t('أدخل عدد اللترات', "Saisissez le nombre de litres"));
      return;
    }
    if (c == null || c < 0) {
      setState(() => error = t('السعر غير صحيح', "Prix invalide"));
      return;
    }
    widget.store.addFuel(FuelEntry(
      id: Store.newId(),
      date: date,
      km: k,
      liters: l,
      cost: c,
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
            Text(t('تعبئة وقود (خزان ممتلئ)', "Plein de carburant (réservoir plein)"),
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
                  labelText: t('العداد (كم)', "Compteur (km)"),
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: liters,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t('عدد اللترات', "Litres"),
                  border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cost,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t('المبلغ المدفوع (دج) - اختياري', "Montant payé (DA) - facultatif"),
                  border: const OutlineInputBorder()),
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

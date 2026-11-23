import 'package:flutter/material.dart';

import 'l10n.dart';
import 'main.dart';

class ChartsPage extends StatelessWidget {
  final Store store;
  const ChartsPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final car = store.car;
        final cs = Theme.of(context).colorScheme;
        final now = DateTime.now();

        // آخر 12 شهراً: مصاريف الصيانة ومصاريف الوقود
        final months = <DateTime>[
          for (var i = 11; i >= 0; i--) DateTime(now.year, now.month - i, 1),
        ];
        final maint = List<double>.filled(12, 0);
        final fuelCost = List<double>.filled(12, 0);
        for (var i = 0; i < 12; i++) {
          final m = months[i];
          for (final s in car.services) {
            if (s.date.year == m.year && s.date.month == m.month) maint[i] += s.cost;
          }
          for (final f in car.fuel) {
            if (f.date.year == m.year && f.date.month == m.month) fuelCost[i] += f.cost;
          }
        }
        var maxV = 0.0;
        for (var i = 0; i < 12; i++) {
          final v = maint[i] + fuelCost[i];
          if (v > maxV) maxV = v;
        }

        // استهلاك الوقود لكل تعبئة (ل/100كم)
        final fs = [...car.fuel]..sort((a, b) => a.km.compareTo(b.km));
        final cons = <double>[];
        for (var i = 1; i < fs.length; i++) {
          final d = fs[i].km - fs[i - 1].km;
          if (d > 0) cons.add(fs[i].liters / d * 100);
        }
        final consShown = cons.length > 12 ? cons.sublist(cons.length - 12) : cons;
        var maxC = 0.0;
        for (final c in consShown) {
          if (c > maxC) maxC = c;
        }

        const h = 150.0;
        final kpd = car.kmPerDay;

        return Scaffold(
          appBar: AppBar(title: Text(t('رسوم بيانية: ${car.label}', "Graphiques : ${car.label}"))),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('المصاريف الشهرية (آخر 12 شهراً)', "Dépenses mensuelles (12 derniers mois)"),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Row(children: [
                        Container(width: 12, height: 12, color: cs.primary),
                        const SizedBox(width: 4),
                        Text(t('صيانة', "Entretien")),
                        const SizedBox(width: 12),
                        Container(width: 12, height: 12, color: Colors.orange),
                        const SizedBox(width: 4),
                        Text(t('وقود', "Carburant")),
                      ]),
                      const SizedBox(height: 12),
                      if (maxV == 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: Text(t('لا توجد مصاريف في هذه الفترة', "Aucune dépense sur cette période"))),
                        )
                      else
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: SizedBox(
                            height: h + 22,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (var i = 0; i < 12; i++)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 2),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.end,
                                        children: [
                                          Container(height: h * fuelCost[i] / maxV, color: Colors.orange),
                                          Container(height: h * maint[i] / maxV, color: cs.primary),
                                          const SizedBox(height: 4),
                                          Text('${months[i].month}', style: const TextStyle(fontSize: 11)),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(t('أعلى شهر: ${fmtMoney(maxV)}', "Mois le plus élevé : ${fmtMoney(maxV)}")),
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('استهلاك الوقود لكل تعبئة (ل/100كم)', "Consommation par plein (L/100 km)"),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      if (consShown.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: Text(t('أضف تعبئتين على الأقل في سجل الوقود', "Ajoutez au moins 2 pleins dans le carburant"))),
                        )
                      else
                        Directionality(
                          textDirection: TextDirection.ltr,
                          child: SizedBox(
                            height: h + 40,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final c in consShown)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 3),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.end,
                                        children: [
                                          Text(c.toStringAsFixed(1), style: const TextStyle(fontSize: 10)),
                                          Container(height: maxC == 0 ? 0 : h * c / maxC, color: Colors.teal),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.speed),
                  title: Text(t('متوسط استعمالك', "Votre usage moyen")),
                  subtitle: Text(kpd == null
                      ? t('يحتاج قراءتين للعداد بينهما 14 يوماً على الأقل', "Il faut 2 relevés du compteur espacés d'au moins 14 jours")
                      : t('${kpd.toStringAsFixed(0)} كم في اليوم (≈ ${fmt((kpd * 30).round())} كم في الشهر)',
                          "${kpd.toStringAsFixed(0)} km par jour (≈ ${fmt((kpd * 30).round())} km par mois)")),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

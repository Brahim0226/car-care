import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'l10n.dart';
import 'main.dart';

/// فئات المصاريف الأخرى: المفتاح، الأيقونة، الاسم عربي/فرنسي
const expenseCats = <String, List<Object>>{
  'fine': [Icons.receipt_long, 'مخالفة', 'Amende'],
  'insurance': [Icons.shield_outlined, 'تأمين', 'Assurance'],
  'vignette': [Icons.confirmation_number_outlined, 'دمغة', 'Vignette'],
  'ct': [Icons.fact_check_outlined, 'مراقبة تقنية', 'Contrôle technique'],
  'wash': [Icons.local_car_wash, 'غسيل', 'Lavage'],
  'parking': [Icons.local_parking, 'موقف / طريق سيّار', 'Parking / péage'],
  'parts': [Icons.settings_outlined, 'قطع غيار', 'Pièces'],
  'acc': [Icons.auto_awesome_outlined, 'كماليات', 'Accessoires'],
  'other': [Icons.more_horiz, 'أخرى', 'Autre'],
};

String expenseCatName(String k) {
  final c = expenseCats[k] ?? expenseCats['other']!;
  return t(c[1] as String, c[2] as String);
}

IconData expenseCatIcon(String k) => (expenseCats[k] ?? expenseCats['other']!)[0] as IconData;

class Expense {
  final String id;
  final DateTime date;
  final String cat;
  final double amount;
  final String note;

  Expense({required this.id, required this.date, required this.cat, required this.amount, this.note = ''});

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'cat': cat,
        'amount': amount,
        'note': note,
      };

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'] as String,
        date: DateTime.parse(j['date'] as String),
        cat: j['cat'] as String? ?? 'other',
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        note: j['note'] as String? ?? '',
      );
}

class ExpensesPage extends StatelessWidget {
  final Store store;
  const ExpensesPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final car = store.car;
        final list = [...car.expenses]..sort((a, b) => b.date.compareTo(a.date));
        final year = DateTime.now().year;
        final total = list.fold<double>(0, (a, e) => a + e.amount);
        final yearTotal = list.where((e) => e.date.year == year).fold<double>(0, (a, e) => a + e.amount);
        final byCat = <String, double>{};
        for (final e in list) {
          byCat[e.cat] = (byCat[e.cat] ?? 0) + e.amount;
        }
        final cats = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        final fuelCost = car.fuel.fold<double>(0, (a, f) => a + f.cost);
        final grand = car.maintenanceCost + fuelCost + total;
        return Scaffold(
          appBar: AppBar(
            title: Text(t('مصاريف أخرى: ${car.label}', 'Autres dépenses : ${car.label}')),
            actions: [
              IconButton(
                tooltip: t('مشاركة الملخص', 'Partager le résumé'),
                icon: const Icon(Icons.share),
                onPressed: () {
                  final b = StringBuffer()
                    ..writeln(t('ملخص مصاريف ${car.label}', 'Résumé des dépenses ${car.label}'))
                    ..writeln(t('صيانة: ${fmtMoney(car.maintenanceCost)}', 'Entretien : ${fmtMoney(car.maintenanceCost)}'))
                    ..writeln(t('وقود: ${fmtMoney(fuelCost)}', 'Carburant : ${fmtMoney(fuelCost)}'));
                  for (final c in cats) {
                    b.writeln('${expenseCatName(c.key)}: ${fmtMoney(c.value)}');
                  }
                  b.writeln(t('المجموع: ${fmtMoney(grand)}', 'Total : ${fmtMoney(grand)}'));
                  Share.share(b.toString());
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => ExpenseForm(store: store),
            ),
            icon: const Icon(Icons.add),
            label: Text(t('مصروف جديد', 'Nouvelle dépense')),
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
                      sumRow(t('هذه السنة ($year)', 'Cette année ($year)'), fmtMoney(yearTotal), bold: true),
                      sumRow(t('كل المصاريف الأخرى', 'Toutes les autres dépenses'), fmtMoney(total)),
                      const Divider(),
                      sumRow(t('صيانة', 'Entretien'), fmtMoney(car.maintenanceCost)),
                      sumRow(t('وقود', 'Carburant'), fmtMoney(fuelCost)),
                      sumRow(t('التكلفة الكلية للسيارة', 'Coût total de la voiture'), fmtMoney(grand), bold: true),
                    ],
                  ),
                ),
              ),
              if (cats.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('حسب النوع', 'Par catégorie'), style: const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        for (final c in cats)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${expenseCatName(c.key)} • ${fmtMoney(c.value)}'),
                                const SizedBox(height: 3),
                                LinearProgressIndicator(value: total > 0 ? c.value / total : 0, minHeight: 8),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: Text(t('لا توجد مصاريف مسجلة بعد', 'Aucune dépense enregistrée'))),
                ),
              for (final e in list)
                Card(
                  child: ListTile(
                    leading: Icon(expenseCatIcon(e.cat)),
                    title: Text('${expenseCatName(e.cat)} • ${fmtMoney(e.amount)}'),
                    subtitle: Text(e.note.isEmpty ? fmtDate(e.date) : '${fmtDate(e.date)} • ${e.note}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (await confirm(context, t('حذف هذا المصروف؟', 'Supprimer cette dépense ?'))) {
                          store.deleteExpense(e);
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

class ExpenseForm extends StatefulWidget {
  final Store store;
  const ExpenseForm({super.key, required this.store});

  @override
  State<ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<ExpenseForm> {
  final amount = TextEditingController();
  final note = TextEditingController();
  DateTime date = DateTime.now();
  String cat = 'fine';
  String? error;

  @override
  void dispose() {
    amount.dispose();
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
    final a = parseDouble(amount.text.trim());
    if (a == null || a <= 0) {
      setState(() => error = t('أدخل المبلغ', 'Saisissez le montant'));
      return;
    }
    widget.store.addExpense(Expense(id: Store.newId(), date: date, cat: cat, amount: a, note: note.text.trim()));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('مصروف جديد', 'Nouvelle dépense'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final k in expenseCats.keys)
                  ChoiceChip(
                    avatar: Icon(expenseCatIcon(k), size: 18),
                    label: Text(expenseCatName(k)),
                    selected: cat == k,
                    onSelected: (_) => setState(() => cat = k),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.event),
              label: Text(t('التاريخ: ${fmtDate(date)}', 'Date : ${fmtDate(date)}')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: t('المبلغ (دج)', 'Montant (DA)'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              decoration: InputDecoration(labelText: t('ملاحظة (اختياري)', 'Note (facultatif)'), border: const OutlineInputBorder()),
            ),
            if (error != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
            const SizedBox(height: 12),
            FilledButton(onPressed: _save, child: Text(t('حفظ', 'Enregistrer'))),
          ],
        ),
      ),
    );
  }
}

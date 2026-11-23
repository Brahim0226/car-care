import 'package:flutter/material.dart';

import 'extras.dart';
import 'l10n.dart';
import 'main.dart';

/// وثيقة للسيارة لها تاريخ انتهاء (تأمين، مراقبة تقنية، دمغة، رخصة…)
class CarDoc {
  final String id;
  final String kind; // insurance | inspection | vignette | license | other
  final String title; // يُستعمل مع kind == other
  final DateTime expiry;

  CarDoc({
    required this.id,
    required this.kind,
    required this.title,
    required this.expiry,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'expiry': expiry.toIso8601String(),
      };

  factory CarDoc.fromJson(Map<String, dynamic> j) => CarDoc(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'other',
        title: j['title'] as String? ?? '',
        expiry: DateTime.parse(j['expiry'] as String),
      );

  String get label {
    switch (kind) {
      case 'insurance':
        return t('التأمين', "Assurance");
      case 'inspection':
        return t('المراقبة التقنية', "Contrôle technique");
      case 'vignette':
        return t('الدمغة (Vignette)', "Vignette");
      case 'license':
        return t('رخصة السياقة', "Permis de conduire");
      default:
        return title.isEmpty ? t('وثيقة', "Document") : title;
    }
  }

  IconData get icon {
    switch (kind) {
      case 'insurance':
        return Icons.shield_outlined;
      case 'inspection':
        return Icons.fact_check_outlined;
      case 'vignette':
        return Icons.confirmation_number_outlined;
      case 'license':
        return Icons.badge_outlined;
      default:
        return Icons.description_outlined;
    }
  }

  int get daysLeft {
    final today = DateTime.now();
    final a = DateTime(today.year, today.month, today.day);
    final b = DateTime(expiry.year, expiry.month, expiry.day);
    return b.difference(a).inDays;
  }

  Status get status {
    final d = daysLeft;
    if (d < 0) {
      return Status(Level.overdue, t('منتهية منذ ${-d} يوم', "Expirée depuis ${-d} j"));
    }
    if (d <= 30) {
      return Status(Level.soon, t('تنتهي بعد $d يوم', "Expire dans $d j"));
    }
    return Status(Level.ok, t('تنتهي بعد $d يوم', "Expire dans $d j"));
  }
}

/// توقعات الاستعمال بناءً على تاريخ قراءات العداد
extension CarPrediction on Car {
  /// متوسط الكيلومترات في اليوم (يحتاج على الأقل 14 يوماً بين أول وآخر قراءة)
  double? get kmPerDay {
    final pts = <MapEntry<DateTime, int>>[];
    for (final s in services) {
      pts.add(MapEntry(s.date, s.km));
    }
    for (final f in fuel) {
      pts.add(MapEntry(f.date, f.km));
    }
    if (pts.length < 2) return null;
    pts.sort((a, b) => a.key.compareTo(b.key));
    var first = pts.first;
    var last = pts.last;
    final now = DateTime.now();
    if (km > last.value && now.isAfter(last.key)) {
      last = MapEntry(now, km);
    }
    final days = last.key.difference(first.key).inDays;
    final dist = last.value - first.value;
    if (days < 14 || dist <= 0) return null;
    return dist / days;
  }

  /// التاريخ المتوقع لبلوغ فاصل الكيلومترات لبند (أو null إذا لا توجد معطيات كافية)
  DateTime? predictedDate(Item it) {
    if (it.intervalKm <= 0) return null;
    final last = lastService(it.id);
    final kpd = kmPerDay;
    if (last == null || kpd == null) return null;
    final rem = last.km + it.intervalKm - km;
    if (rem <= 0) return null;
    return DateTime.now().add(Duration(days: (rem / kpd).round()));
  }
}

class DocsPage extends StatelessWidget {
  final Store store;
  const DocsPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final car = store.car;
        final list = [...car.docs]..sort((a, b) => a.expiry.compareTo(b.expiry));
        return Scaffold(
          appBar: AppBar(title: Text(t('وثائق ${car.label}', "Documents : ${car.label}"))),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => DocForm(store: store),
            ),
            icon: const Icon(Icons.add),
            label: Text(t('إضافة وثيقة', "Ajouter un document")),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            children: [
              Text(
                t('سجّل تاريخ انتهاء كل وثيقة، وسيصلك إشعار قبل شهر وقبل أسبوع وفي يوم الانتهاء.',
                    "Saisissez la date d'expiration de chaque document : vous serez prévenu un mois et une semaine avant, puis le jour même."),
              ),
              const SizedBox(height: 8),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: Text(t('لا توجد وثائق بعد', "Aucun document"))),
                ),
              for (final d in list)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: d.status.color.withOpacity(0.15),
                      child: Icon(d.icon, color: d.status.color),
                    ),
                    title: Text(d.label),
                    subtitle: Text(
                      '${fmtDate(d.expiry)} • ${d.status.text}',
                      style: TextStyle(color: d.status.color),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: t('إلى التقويم', "Vers l'agenda"),
                          icon: const Icon(Icons.event_available),
                          onPressed: () => addToCalendar(
                              context,
                              t('انتهاء ${d.label} (${car.label})', "Expiration ${d.label} (${car.label})"),
                              d.expiry),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await confirm(context, t('حذف هذه الوثيقة؟', "Supprimer ce document ?"))) {
                              store.deleteDoc(d);
                            }
                          },
                        ),
                      ],
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

class DocForm extends StatefulWidget {
  final Store store;
  const DocForm({super.key, required this.store});

  @override
  State<DocForm> createState() => _DocFormState();
}

class _DocFormState extends State<DocForm> {
  String kind = 'insurance';
  final TextEditingController title = TextEditingController();
  DateTime expiry = DateTime.now().add(const Duration(days: 365));
  String? error;

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final d = await showDatePicker(
      context: context,
      initialDate: expiry,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => expiry = d);
  }

  void _save() {
    if (kind == 'other' && title.text.trim().isEmpty) {
      setState(() => error = t('اكتب اسم الوثيقة', "Saisissez le nom du document"));
      return;
    }
    widget.store.addDoc(CarDoc(
      id: Store.newId(),
      kind: kind,
      title: title.text.trim(),
      expiry: expiry,
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final kinds = <String, String>{
      'insurance': t('التأمين', "Assurance"),
      'inspection': t('المراقبة التقنية', "Contrôle technique"),
      'vignette': t('الدمغة (Vignette)', "Vignette"),
      'license': t('رخصة السياقة', "Permis de conduire"),
      'other': t('وثيقة أخرى', "Autre document"),
    };
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('وثيقة جديدة', "Nouveau document"),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final e in kinds.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: kind == e.key,
                    onSelected: (_) => setState(() => kind = e.key),
                  ),
              ],
            ),
            if (kind == 'other') ...[
              const SizedBox(height: 12),
              TextField(
                controller: title,
                decoration: InputDecoration(
                    labelText: t('اسم الوثيقة', "Nom du document"),
                    border: const OutlineInputBorder()),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.event),
              label: Text(t('تاريخ الانتهاء: ${fmtDate(expiry)}', "Date d'expiration : ${fmtDate(expiry)}")),
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

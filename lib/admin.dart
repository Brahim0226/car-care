import 'package:flutter/material.dart';

import 'l10n.dart';
import 'main.dart';
import 'sync.dart';

/// شاشة إحصائيات المشرف: تُفتح بضغطة طويلة على عنوان «حول التطبيق» ثم إدخال الرمز
Future<void> adminEntry(BuildContext context, Store store) async {
  final c = TextEditingController(text: store.prefs.getString('adminCode') ?? '');
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t('رمز المشرف', "Code administrateur")),
      content: TextField(
        controller: c,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('إلغاء', "Annuler"))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
  c.dispose();
  if (code == null || code.isEmpty || !context.mounted) return;
  final stats = await fetchInstallStats(code);
  if (!context.mounted) return;
  if (stats == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t('الرمز غير صحيح أو لا يوجد اتصال', "Code incorrect ou pas de connexion"))));
    return;
  }
  await store.prefs.setString('adminCode', code);
  if (!context.mounted) return;
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => AdminPage(code: code, first: stats)),
  );
}

class AdminPage extends StatefulWidget {
  final String code;
  final Map<String, dynamic> first;
  const AdminPage({super.key, required this.code, required this.first});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  late Map<String, dynamic> s = widget.first;
  bool loading = false;

  Future<void> _refresh() async {
    setState(() => loading = true);
    final n = await fetchInstallStats(widget.code);
    if (!mounted) return;
    setState(() {
      loading = false;
      if (n != null) s = n;
    });
  }

  Widget _tile(String label, Object? v) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
            child: Column(
              children: [
                Text('${v ?? 0}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      );

  Widget _list(String title, List items, String k, String v) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              if (items.isEmpty) const Text('-'),
              for (final e in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [Text('${(e as Map)[k]}'), Text('${e[v]}')],
                  ),
                ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final latest = s['latest'] as String?;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('إحصائيات المستعملين', "Statistiques")),
        actions: [
          IconButton(onPressed: loading ? null : _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(children: [
            _tile(t('كل الأجهزة', "Appareils"), s['total']),
            _tile(t('نشطة 7 أيام', "Actifs 7 j"), s['active7']),
            _tile(t('نشطة 30 يوماً', "Actifs 30 j"), s['active30']),
          ]),
          Row(children: [
            _tile(t('نشطة اليوم', "Aujourd'hui"), s['today']),
            _tile(t('مرات الفتح', "Ouvertures"), s['opens']),
          ]),
          if (latest != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(t('آخر ظهور: ${DateTime.parse(latest).toLocal().toString().substring(0, 16)}',
                  "Dernière activité : ${DateTime.parse(latest).toLocal().toString().substring(0, 16)}")),
            ),
          _list(t('الإصدارات', "Versions"), (s['versions'] as List?) ?? [], 'v', 'n'),
          _list(t('اللغات', "Langues"), (s['langs'] as List?) ?? [], 'l', 'n'),
          _list(t('أجهزة جديدة كل يوم (30 يوماً)', "Nouveaux appareils par jour (30 j)"),
              ((s['daily'] as List?) ?? []).reversed.toList(), 'd', 'n'),
        ],
      ),
    );
  }
}

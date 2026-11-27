import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'dtc.dart';
import 'l10n.dart';
import 'main.dart';

// ====================== خيارات الحساب ======================

class ReportOptions {
  final Set<String> carIds;
  final bool purchase;
  final bool maintenance;
  final Set<String> itemIds;

  const ReportOptions({
    required this.carIds,
    required this.purchase,
    required this.maintenance,
    required this.itemIds,
  });
}

class CarReport {
  final Car car;
  final double purchase; // 0 إذا لم يُختر أو غير مسجل
  final double maintenance;
  final List<Service> rows;

  CarReport(this.car, this.purchase, this.maintenance, this.rows);

  double get total => purchase + maintenance;
}

/// يحسب فقط ما اختاره المستخدم
List<CarReport> computeReport(Store store, ReportOptions o) {
  final out = <CarReport>[];
  for (final car in store.cars) {
    if (!o.carIds.contains(car.id)) continue;
    final p = o.purchase ? (car.purchasePrice ?? 0.0) : 0.0;
    final rows = o.maintenance
        ? (car.services.where((s) => o.itemIds.contains(s.itemId)).toList()
          ..sort((a, b) => a.date.compareTo(b.date)))
        : <Service>[];
    final m = rows.fold<double>(0, (a, s) => a + s.cost);
    out.add(CarReport(car, p, m, rows));
  }
  return out;
}

// ====================== رسم الصفحات ======================
// نرسم كل صفحة بمحرك نصوص Flutter (يدعم العربية بشكل صحيح) ثم نضعها صورة داخل PDF.

class _Pager {
  static const double pageW = 1240; // A4 بدقة 150dpi
  static const double pageH = 1754;
  static const double margin = 80;
  static const List<double> colW = [340, 190, 190, 200, 160];

  final List<Uint8List> pages = [];
  late ui.PictureRecorder _rec;
  late Canvas _canvas;
  double y = margin;
  List<String>? tableHeader;

  void begin() {
    _rec = ui.PictureRecorder();
    _canvas = Canvas(_rec, const Rect.fromLTWH(0, 0, pageW, pageH));
    _canvas.drawRect(
      const Rect.fromLTWH(0, 0, pageW, pageH),
      Paint()..color = Colors.white,
    );
    y = margin;
  }

  Future<void> end() async {
    _paint(
      t('صفحة ${pages.length + 1}', "Page ${pages.length + 1}"),
      x: margin,
      width: pageW - 2 * margin,
      top: pageH - 70,
      size: 22,
      color: Colors.grey,
      align: TextAlign.center,
      maxLines: 1,
    );
    final pic = _rec.endRecording();
    final img = await pic.toImage(pageW.toInt(), pageH.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    pages.add(data!.buffer.asUint8List());
    img.dispose();
    pic.dispose();
  }

  double _paint(
    String s, {
    required double x,
    required double width,
    required double top,
    double size = 26,
    bool bold = false,
    Color color = Colors.black,
    TextAlign? align,
    int maxLines = 2,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: size,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          color: color,
          height: 1.3,
        ),
      ),
      textDirection: Lang.dir,
      textAlign: align ?? Lang.start,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(minWidth: width, maxWidth: width);
    tp.paint(_canvas, Offset(x, top));
    return tp.height;
  }

  Future<void> ensure(double need) async {
    if (y + need <= pageH - margin - 40) return;
    await end();
    begin();
    final h = tableHeader;
    if (h != null) _drawRow(h, header: true);
  }

  Future<void> line(
    String s, {
    double size = 26,
    bool bold = false,
    Color color = Colors.black,
    TextAlign? align,
    double gap = 10,
  }) async {
    await ensure(size * 1.6 + gap);
    final h = _paint(
      s,
      x: margin,
      width: pageW - 2 * margin,
      top: y,
      size: size,
      bold: bold,
      color: color,
      align: align,
      maxLines: 3,
    );
    y += h + gap;
  }

  void space(double h) => y += h;

  Future<void> rule() async {
    await ensure(20);
    _canvas.drawRect(
      Rect.fromLTWH(margin, y, pageW - 2 * margin, 2),
      Paint()..color = Colors.black26,
    );
    y += 16;
  }

  void _drawRow(List<String> cells, {bool header = false, bool shade = false}) {
    const h = 48.0;
    if (header) {
      _canvas.drawRect(
        Rect.fromLTWH(margin, y, pageW - 2 * margin, h),
        Paint()..color = const Color(0xFF1565C0),
      );
    } else if (shade) {
      _canvas.drawRect(
        Rect.fromLTWH(margin, y, pageW - 2 * margin, h),
        Paint()..color = const Color(0xFFF1F4F9),
      );
    }
    // العربية: الأعمدة من اليمين لليسار. الفرنسية: من اليسار لليمين.
    var edge = Lang.fr ? margin : pageW - margin;
    for (var i = 0; i < cells.length && i < colW.length; i++) {
      final w = colW[i];
      final left = Lang.fr ? edge : edge - w;
      _paint(
        cells[i],
        x: left + 8,
        width: w - 16,
        top: y + 9,
        size: 24,
        bold: header,
        color: header ? Colors.white : Colors.black,
        align: i == 0 ? Lang.start : TextAlign.center,
        maxLines: 1,
      );
      edge += Lang.fr ? w : -w;
    }
    y += h;
  }

  Future<void> startTable(List<String> header) async {
    tableHeader = header;
    await ensure(48 * 2);
    _drawRow(header, header: true);
  }

  Future<void> row(List<String> cells, {bool shade = false}) async {
    await ensure(48);
    _drawRow(cells, shade: shade);
  }

  void endTable() {
    tableHeader = null;
  }
}

Future<Uint8List> buildReportPdf(Store store, ReportOptions o) async {
  final data = computeReport(store, o);
  final p = _Pager()..begin();

  await p.line(t('تقرير السيارات', "Rapport des voitures"), size: 46, bold: true, color: const Color(0xFF1565C0));
  await p.line(t('تاريخ الإنشاء: ${fmtDate(DateTime.now())}', "Créé le : ${fmtDate(DateTime.now())}"), size: 24, color: Colors.grey, gap: 18);
  await p.rule();

  var sumPurchase = 0.0;
  var sumMaint = 0.0;

  for (final r in data) {
    final car = r.car;
    sumPurchase += r.purchase;
    sumMaint += r.maintenance;

    p.space(10);
    await p.line(car.label, size: 36, bold: true, gap: 4);
    await p.line(t('العداد: ${fmt(car.km)} كم', "Compteur : ${fmt(car.km)} km"), size: 24, color: Colors.black54, gap: 12);

    if (o.purchase) {
      await p.line(
        car.purchasePrice == null
            ? t('ثمن الشراء: غير مسجل', "Prix d'achat : non renseigné")
            : t('ثمن الشراء: ${fmtMoney(car.purchasePrice!)}', "Prix d'achat : ${fmtMoney(car.purchasePrice!)}"),
        size: 28,
        gap: 12,
      );
    }

    if (o.maintenance) {
      if (r.rows.isEmpty) {
        await p.line(t('لا توجد صيانات مطابقة للاختيار', "Aucun entretien correspondant à la sélection"), size: 24, color: Colors.black54);
      } else {
        await p.startTable([t('البند', "Élément"), t('التاريخ', "Date"), t('العداد (كم)', "Compteur (km)"), t('السعر (دج)', "Prix (DA)"), t('ملاحظة', "Remarque")]);
        var i = 0;
        for (final s in r.rows) {
          await p.row([
            car.itemById(s.itemId)?.label ?? t('بند محذوف', "Élément supprimé"),
            fmtDate(s.date),
            fmt(s.km),
            s.cost > 0 ? fmt(s.cost.round()) : '—',
            s.note,
          ], shade: i.isOdd);
          i++;
        }
        p.endTable();
        p.space(10);
        await p.line(t('مجموع الصيانة: ${fmtMoney(r.maintenance)}', "Total entretien : ${fmtMoney(r.maintenance)}"), size: 28, gap: 8);
      }
    }

    await p.line(
      t('إجمالي ${car.label}: ${fmtMoney(r.total)}', "Total ${car.label} : ${fmtMoney(r.total)}"),
      size: 30,
      bold: true,
      gap: 14,
    );
    await p.rule();
  }

  p.space(8);
  await p.line(t('الإجمالي العام', "Total général"), size: 38, bold: true, gap: 8);
  if (o.purchase) {
    await p.line(t('مجموع ثمن الشراء: ${fmtMoney(sumPurchase)}', "Total prix d'achat : ${fmtMoney(sumPurchase)}"), size: 28, gap: 6);
  }
  if (o.maintenance) {
    await p.line(t('مجموع الصيانة: ${fmtMoney(sumMaint)}', "Total entretien : ${fmtMoney(sumMaint)}"), size: 28, gap: 6);
  }
  await p.line(
    t('المجموع: ${fmtMoney(sumPurchase + sumMaint)}', "Total : ${fmtMoney(sumPurchase + sumMaint)}"),
    size: 42,
    bold: true,
    color: const Color(0xFF1565C0),
  );
  await p.end();

  final doc = pw.Document();
  for (final png in p.pages) {
    final img = pw.MemoryImage(png);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (ctx) => pw.FullPage(
          ignoreMargins: true,
          child: pw.Image(img, fit: pw.BoxFit.fill),
        ),
      ),
    );
  }
  return doc.save();
}

/// تقرير فحص OBD (PDF) للسيارة
Future<Uint8List> buildObdReportPdf({
  required Car car,
  required List<String> stored,
  required List<String> pending,
  required Map<String, String> live,
  String? odoKm,
  String? adapter,
}) async {
  final p = _Pager()..begin();
  await p.line(t('تقرير فحص السيارة (OBD)', 'Rapport de diagnostic (OBD)'), size: 46, bold: true, color: const Color(0xFF1565C0));
  await p.line(t('التاريخ: ${fmtDate(DateTime.now())}', 'Date : ${fmtDate(DateTime.now())}'), size: 24, color: Colors.grey, gap: 14);
  await p.rule();
  p.space(8);
  await p.line(car.label, size: 36, bold: true, gap: 4);
  await p.line(t('العداد المسجل: ${fmt(car.km)} كم', 'Compteur enregistré : ${fmt(car.km)} km'), size: 24, color: Colors.black54, gap: 4);
  if (odoKm != null) {
    await p.line(t('العداد من السيارة: $odoKm كم', 'Compteur lu sur la voiture : $odoKm km'), size: 24, color: Colors.black54, gap: 4);
  }
  if (adapter != null && adapter.isNotEmpty) {
    await p.line(t('المحوّل: $adapter', 'Adaptateur : $adapter'), size: 22, color: Colors.black54, gap: 4);
  }
  p.space(10);

  Future<void> section(String title, List<String> codes) async {
    await p.line(title, size: 30, bold: true, gap: 8);
    if (codes.isEmpty) {
      await p.line(t('لا توجد أعطال ✔', 'Aucun défaut ✔'), size: 26, gap: 12);
    } else {
      for (final c in codes) {
        await p.line('$c  —  ${dtcExplain(c)}', size: 26, gap: 8);
      }
      p.space(6);
    }
  }

  await section(t('أعطال مخزّنة', 'Défauts enregistrés'), stored);
  await section(t('أعطال قيد الرصد', 'Défauts en attente'), pending);

  if (live.isNotEmpty) {
    p.space(6);
    await p.line(t('بيانات حية لحظة الفحص', 'Données en direct'), size: 30, bold: true, gap: 8);
    for (final e in live.entries) {
      await p.line('${e.key}: ${e.value}', size: 26, gap: 6);
    }
  }
  p.space(12);
  await p.rule();
  await p.line(
      t('تنبيه: هذا التقرير للاسترشاد، ويُنصح بتأكيد العطل عند ميكانيكي مختص.',
          "Remarque : ce rapport est indicatif, faites confirmer le défaut par un mécanicien."),
      size: 20,
      color: Colors.grey);
  await p.end();

  final doc = pw.Document();
  for (final png in p.pages) {
    final img = pw.MemoryImage(png);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (ctx) => pw.FullPage(ignoreMargins: true, child: pw.Image(img, fit: pw.BoxFit.fill)),
      ),
    );
  }
  return doc.save();
}

// ====================== شاشة التقرير ======================

class ReportPage extends StatefulWidget {
  final Store store;
  const ReportPage({super.key, required this.store});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  late final Set<String> carIds = widget.store.cars.map((c) => c.id).toSet();
  late final Map<String, String> allItems = _collectItems();
  late final Set<String> itemIds = allItems.keys.toSet();
  bool purchase = true;
  bool maint = true;
  bool busy = false;

  Map<String, String> _collectItems() {
    final m = <String, String>{};
    for (final c in widget.store.cars) {
      for (final it in c.items) {
        m.putIfAbsent(it.id, () => it.label);
      }
    }
    return m;
  }

  ReportOptions get opts => ReportOptions(
        carIds: carIds,
        purchase: purchase,
        maintenance: maint,
        itemIds: itemIds,
      );

  Future<void> _make(bool share) async {
    setState(() => busy = true);
    try {
      final bytes = await buildReportPdf(widget.store, opts);
      if (share) {
        await Printing.sharePdf(bytes: bytes, filename: 'car_report.pdf');
      } else {
        await Printing.layoutPdf(
          onLayout: (_) async => bytes,
          name: 'car_report.pdf',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('تعذّر إنشاء التقرير: $e', "Impossible de créer le rapport : $e"))),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final data = computeReport(store, opts);
    final sumP = data.fold<double>(0, (a, r) => a + r.purchase);
    final sumM = data.fold<double>(0, (a, r) => a + r.maintenance);
    final hasPrice = data.any((r) => r.car.purchasePrice != null);
    final canMake = carIds.isNotEmpty && (purchase || maint) && !busy;

    return Scaffold(
      appBar: AppBar(title: Text(t('تقرير PDF', "Rapport PDF"))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(t('السيارات', "Voitures"),
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          Card(
            child: Column(
              children: [
                for (final c in store.cars)
                  CheckboxListTile(
                    value: carIds.contains(c.id),
                    title: Text(c.label),
                    subtitle: Text(c.purchasePrice == null
                        ? t('بدون ثمن شراء', "Sans prix d'achat")
                        : t('ثمن الشراء: ${fmtMoney(c.purchasePrice!)}', "Prix d'achat : ${fmtMoney(c.purchasePrice!)}")),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        carIds.add(c.id);
                      } else {
                        carIds.remove(c.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(t('ماذا يظهر في التقرير', "Contenu du rapport"),
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(t('ثمن شراء السيارة', "Prix d'achat de la voiture")),
                  subtitle: hasPrice || carIds.isEmpty
                      ? null
                      : Text(t('لا يوجد ثمن شراء مسجل للسيارات المختارة', "Aucun prix d'achat renseigné pour les voitures choisies")),
                  value: purchase,
                  onChanged: (v) => setState(() => purchase = v),
                ),
                SwitchListTile(
                  title: Text(t('الصيانة', "Entretien")),
                  value: maint,
                  onChanged: (v) => setState(() => maint = v),
                ),
                if (maint)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final e in allItems.entries)
                          FilterChip(
                            label: Text(e.value),
                            selected: itemIds.contains(e.key),
                            onSelected: (v) => setState(() {
                              if (v) {
                                itemIds.add(e.key);
                              } else {
                                itemIds.remove(e.key);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  if (purchase) sumRow(t('ثمن الشراء', "Prix d'achat"), fmtMoney(sumP)),
                  if (maint) sumRow(t('الصيانة', "Entretien"), fmtMoney(sumM)),
                  const Divider(),
                  sumRow(t('المجموع', "Total"), fmtMoney(sumP + sumM), bold: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: canMake ? () => _make(false) : null,
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf),
            label: Text(t('معاينة / طباعة / حفظ PDF', "Aperçu / Imprimer / Enregistrer PDF")),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: canMake ? () => _make(true) : null,
            icon: const Icon(Icons.share),
            label: Text(t('مشاركة PDF', "Partager le PDF")),
          ),
        ],
      ),
    );
  }
}

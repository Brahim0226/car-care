import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dtc.dart';
import 'l10n.dart';
import 'license.dart';
import 'main.dart';
import 'report.dart';
import 'sync.dart';

/// اتصال بمحوّل ELM327 عبر بلوتوث عادي (SPP) وإرسال أوامر OBD-II
class Elm {
  final dynamic _bt = FlutterClassicBluetooth();
  dynamic _conn;
  StreamSubscription<dynamic>? _sub;
  final StringBuffer _buf = StringBuffer();
  Completer<String>? _wait;
  bool connected = false;
  final List<String> log = [];

  Future<List<dynamic>> pairedDevices() async {
    final l = await _bt.getPairedDevices();
    return List<dynamic>.from(l as Iterable);
  }

  Future<void> connect(String address) async {
    _conn = await _bt.connect(address: address);
    _sub = _conn.input.listen((dynamic d) {
      _buf.write(String.fromCharCodes(List<int>.from(d as Iterable)));
      final s = _buf.toString();
      if (s.contains('>')) {
        _buf.clear();
        final w = _wait;
        _wait = null;
        if (w != null && !w.isCompleted) w.complete(s);
      }
    }, onDone: () {
      connected = false;
    });
    connected = true;
  }

  /// يرسل أمراً ويرجع أسطر الرد (بدون الصدى والمؤشر >)
  Future<List<String>> cmd(String c, {int ms = 6000}) async {
    _buf.clear();
    final w = Completer<String>();
    _wait = w;
    await _conn.output.writeString('$c\r');
    String raw;
    try {
      raw = await w.future.timeout(Duration(milliseconds: ms));
    } on TimeoutException {
      _wait = null;
      raw = _buf.toString();
      log.add('$c -> (timeout) $raw');
      return raw.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    final lines = raw
        .replaceAll('>', '')
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e.toUpperCase() != c.toUpperCase())
        .toList();
    log.add('$c -> ${lines.join(' | ')}');
    if (log.length > 40) log.removeAt(0);
    return lines;
  }

  Future<void> init() async {
    await cmd('ATZ', ms: 4000);
    await cmd('ATE0');
    await cmd('ATL0');
    await cmd('ATS0');
    await cmd('ATH0');
    await cmd('ATSP0');
  }

  /// يجمع ردود الإطارات المتعددة في رسائل نصية (HEX بدون مسافات)
  List<String> messages(List<String> lines) {
    final out = <String>[];
    final cont = RegExp(r'^[0-9A-Fa-f]:(.*)$');
    final lenHeader = RegExp(r'^[0-9A-Fa-f]{3}$');
    for (final raw in lines) {
      final l = raw.trim();
      final m = cont.firstMatch(l);
      if (m != null) {
        final part = m.group(1)!.replaceAll(' ', '').toUpperCase();
        if (out.isEmpty) {
          out.add(part);
        } else {
          out[out.length - 1] = out.last + part;
        }
      } else if (lenHeader.hasMatch(l)) {
        out.add('');
      } else {
        final h = l.replaceAll(' ', '').toUpperCase();
        if (RegExp(r'^[0-9A-F]+$').hasMatch(h)) out.add(h);
      }
    }
    return out.where((e) => e.isNotEmpty).toList();
  }

  /// يقرأ PID من الوضع 01 ويرجع البايتات بعد 41xx، أو null
  Future<List<int>?> pid(String p) async {
    final lines = await cmd('01$p');
    final head = '41$p'.toUpperCase();
    for (final m in messages(lines)) {
      final i = m.indexOf(head);
      if (i >= 0) {
        final d = m.substring(i + 4);
        final b = <int>[];
        for (var k = 0; k + 1 < d.length; k += 2) {
          b.add(int.parse(d.substring(k, k + 2), radix: 16));
        }
        return b;
      }
    }
    return null;
  }

  List<String> _decodeDtcs(List<String> lines, String head) {
    final res = <String>[];
    for (final m in messages(lines)) {
      if (!m.startsWith(head)) continue;
      final d = m.substring(head.length);
      for (var k = 0; k + 3 < d.length; k += 4) {
        final b1 = int.parse(d.substring(k, k + 2), radix: 16);
        final b2 = int.parse(d.substring(k + 2, k + 4), radix: 16);
        if (b1 == 0 && b2 == 0) continue;
        final letter = ['P', 'C', 'B', 'U'][(b1 >> 6) & 3];
        final d1 = (b1 >> 4) & 3;
        final d2 = (b1 & 15).toRadixString(16);
        final low = b2.toRadixString(16).padLeft(2, '0');
        final code = '$letter$d1$d2$low'.toUpperCase();
        if (!res.contains(code)) res.add(code);
      }
    }
    return res;
  }

  Future<List<String>> storedDtcs() async => _decodeDtcs(await cmd('03', ms: 10000), '43');
  Future<List<String>> pendingDtcs() async => _decodeDtcs(await cmd('07', ms: 10000), '47');

  Future<bool> clearDtcs() async {
    final lines = await cmd('04', ms: 10000);
    return messages(lines).any((m) => m.startsWith('44'));
  }

  Future<void> close() async {
    connected = false;
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      await _conn?.close();
      _conn?.dispose();
    } catch (_) {}
  }
}

class ObdPage extends StatefulWidget {
  final Store store;
  const ObdPage({super.key, required this.store});

  @override
  State<ObdPage> createState() => _ObdPageState();
}

class _ObdPageState extends State<ObdPage> {
  final Elm elm = Elm();
  List<dynamic> devices = [];
  String status = '';
  String adapterName = '';
  String elmVersion = '';
  String protocol = '';
  String? odoKm;
  bool busy = false;
  bool ready = false;
  List<String>? stored;
  List<String>? pending;
  Map<String, String> live = {};
  License? lic;

  Tier get tier => lic?.tier ?? Tier.none;

  @override
  void initState() {
    super.initState();
    _loadLic();
  }

  Future<void> _loadLic() async {
    final l = await currentLicense(widget.store, widget.store.car.id);
    if (mounted) setState(() => lic = l);
  }

  /// يتأكد من مستوى الاشتراك قبل تنفيذ ميزة، وإلا يعرض نافذة التفعيل
  Future<bool> _need(Tier tr) async {
    if (tier.index >= tr.index) return true;
    final pro = tr == Tier.pro;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr == Tier.pro ? t('اشتراك كامل مطلوب', 'Abonnement complet requis') : t('اشتراك مطلوب', 'Abonnement requis')),
        content: Text(pro
            ? t('هذه الميزة (البيانات الحية، مسح الأعطال، جلب العداد) ضمن الاشتراك الكامل.',
                "Cette fonction (données en direct, effacement des codes, compteur) fait partie de l'abonnement complet.")
            : t('قراءة الأعطال ضمن الاشتراك الأساسي. يمكنك اختبار الاتصال مجاناً.',
                "La lecture des défauts fait partie de l'abonnement de base. Vous pouvez tester la connexion gratuitement.")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('إغلاق', 'Fermer'))),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _activateDialog();
            },
            child: Text(t('تفعيل', 'Activer')),
          ),
        ],
      ),
    );
    return false;
  }

  Future<void> _whatsapp(dynamic car, bool pro) async {
    final tier = pro ? t('الكامل', 'Complet') : t('الأساسي', 'De base');
    final msg = t(
        'السلام عليكم، أريد اشتراك OBD ($tier).\nمعرّف السيارة: ${car.id}\nالسيارة: ${car.label}\nالتطبيق: $appVersion',
        "Bonjour, je souhaite l'abonnement OBD ($tier).\nIdentifiant : ${car.id}\nVoiture : ${car.label}\nApp : $appVersion");
    final ok = await launchUrl(waUrl(msg), mode: LaunchMode.externalApplication);
    if (!ok) _msg(t('تعذّر فتح واتساب', "Impossible d'ouvrir WhatsApp"));
  }

  Future<void> _activateDialog() async {
    final car = widget.store.car;
    final ctl = TextEditingController();
    String err = '';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t('تفعيل الاشتراك', "Activer l'abonnement")),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('1) أرسل معرّف هذه السيارة للمطوّر:', "1) Envoyez l'identifiant de cette voiture au développeur :")),
                const SizedBox(height: 6),
                SelectableText(car.id, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                Row(children: [
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: car.id));
                      _msg(t('تم النسخ', 'Copié'));
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(t('نسخ', 'Copier')),
                  ),
                  TextButton.icon(
                    onPressed: () => Share.share('Car ID: ${car.id}\n${car.label}\nApp: $appVersion'),
                    icon: const Icon(Icons.share, size: 18),
                    label: Text(t('إرسال', 'Envoyer')),
                  ),
                ]),
                Wrap(spacing: 8, children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _whatsapp(car, false),
                    icon: const Icon(Icons.chat, size: 18),
                    label: Text(t('طلب «أساسي» (واتساب)', 'Demander « De base »')),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _whatsapp(car, true),
                    icon: const Icon(Icons.chat, size: 18),
                    label: Text(t('طلب «كامل» (واتساب)', 'Demander « Complet »')),
                  ),
                ]),
                if (canStartTrial(widget.store, car.id))
                  OutlinedButton.icon(
                    onPressed: () async {
                      await startTrial(widget.store, car.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                      await _loadLic();
                      _msg(t('بدأت التجربة المجانية ($trialDays أيام، الاشتراك الأساسي) ✅', 'Essai gratuit démarré ($trialDays jours, abonnement de base) ✅'));
                    },
                    icon: const Icon(Icons.card_giftcard, size: 18),
                    label: Text(t('تجربة مجانية $trialDays أيام (الأساسي)', 'Essai gratuit $trialDays jours (de base)')),
                  ),
                const SizedBox(height: 8),
                Text(t('2) ألصق الكود الذي تستلمه هنا:', '2) Collez ici le code reçu :')),
                const SizedBox(height: 6),
                TextField(controller: ctl, maxLines: 3, decoration: const InputDecoration(border: OutlineInputBorder())),
                if (err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(err, style: const TextStyle(color: Colors.red))),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('إلغاء', 'Annuler'))),
            FilledButton(
              onPressed: () async {
                final l = await activateLicense(widget.store, car.id, ctl.text);
                if (l == null) {
                  setD(() => err = t('الكود غير صالح لهذه السيارة', 'Code invalide pour cette voiture'));
                  return;
                }
                if (ctx.mounted) Navigator.pop(ctx);
                await _loadLic();
                _msg(t('تم تفعيل الاشتراك ✅', 'Abonnement activé ✅'));
              },
              child: Text(t('تفعيل', 'Activer')),
            ),
          ],
        ),
      ),
    );
  }

  String _licText() {
    final l = lic;
    if (l == null) return t('غير مفعّل', 'Non activé');
    final d = '${l.expiry.year}-${l.expiry.month.toString().padLeft(2, '0')}-${l.expiry.day.toString().padLeft(2, '0')}';
    final name = (l.trial ? t('تجربة ', 'Essai ') : '') + (l.tier == Tier.pro ? t('كامل', 'Complet') : t('أساسي', 'De base'));
    return t('$name حتى $d', '$name jusqu\'au $d');
  }

  @override
  void dispose() {
    _liveOn = false;
    elm.close();
    super.dispose();
  }

  void _msg(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _loadDevices() async {
    setState(() {
      busy = true;
      status = '';
    });
    try {
      await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
      final l = await elm.pairedDevices();
      if (!mounted) return;
      setState(() {
        devices = l;
        if (l.isEmpty) {
          status = t('لا توجد أجهزة مقترنة. اقرن المحوّل أولاً من إعدادات البلوتوث في الهاتف (الرمز غالباً 1234 أو 0000).',
              "Aucun appareil associé. Associez d'abord l'adaptateur dans les réglages Bluetooth du téléphone (code souvent 1234 ou 0000).");
        }
      });
    } catch (e) {
      if (mounted) setState(() => status = t('تعذّر قراءة الأجهزة: $e', "Impossible de lire les appareils : $e"));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _connect(dynamic dev) async {
    setState(() {
      busy = true;
      ready = false;
      stored = null;
      pending = null;
      live = {};
      odoKm = null;
      status = t('جارٍ الاتصال...', 'Connexion...');
    });
    try {
      adapterName = '${dev.displayName}';
      await elm.connect('${dev.address}');
      setState(() => status = t('تهيئة المحوّل...', "Initialisation de l'adaptateur..."));
      await elm.init();
      final v = await elm.cmd('ATI');
      elmVersion = v.isNotEmpty ? v.last : '';
      // أول طلب يبحث عن البروتوكول (قد يستغرق عدة ثوانٍ)
      setState(() => status = t('الاتصال بالسيارة (شغّل الاحتراق)...', "Connexion à la voiture (mettez le contact)..."));
      final r = await elm.cmd('0100', ms: 20000);
      final ok = elm.messages(r).any((m) => m.contains('4100'));
      final p = await elm.cmd('ATDPN');
      protocol = p.isNotEmpty ? p.last : '';
      if (!mounted) return;
      setState(() {
        ready = ok;
        status = ok
            ? t('متصل بالسيارة ✅', 'Connecté à la voiture ✅')
            : t('اتصل بالمحوّل لكن السيارة لم تردّ. شغّل الاحتراق وأعد المحاولة.',
                "Adaptateur connecté mais la voiture ne répond pas. Mettez le contact et réessayez.");
      });
    } catch (e) {
      if (mounted) setState(() => status = t('فشل الاتصال: $e', 'Échec de connexion : $e'));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _readDtcs() async {
    if (!await _need(Tier.basic)) return;
    await _stopLive();
    setState(() => busy = true);
    try {
      final s = await elm.storedDtcs();
      final p = await elm.pendingDtcs();
      if (!mounted) return;
      setState(() {
        stored = s;
        pending = p;
      });
      _logDtcs(s, p);
    } catch (e) {
      _msg(t('فشلت القراءة: $e', 'Échec de lecture : $e'));
    }
    if (mounted) setState(() => busy = false);
  }

  void _logDtcs(List<String> s, List<String> p) {
    try {
      final prefs = widget.store.prefs;
      final all = (jsonDecode(prefs.getString('dtcLog') ?? '[]') as List).cast<Map<String, dynamic>>();
      all.add({'car': widget.store.car.id, 'd': DateTime.now().toIso8601String().substring(0, 16), 's': s, 'p': p});
      final keep = all.length > 80 ? all.sublist(all.length - 80) : all;
      prefs.setString('dtcLog', jsonEncode(keep));
    } catch (_) {}
  }

  void _history() {
    List<Map<String, dynamic>> rows = [];
    try {
      rows = (jsonDecode(widget.store.prefs.getString('dtcLog') ?? '[]') as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['car'] == widget.store.car.id)
          .toList()
          .reversed
          .toList();
    } catch (_) {}
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Directionality(
        textDirection: Lang.dir,
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
            child: rows.isEmpty
                ? Padding(padding: const EdgeInsets.all(24), child: Text(t('لا يوجد سجل بعد. يُحفظ كل فحص تلقائياً.', "Aucun historique. Chaque lecture est enregistrée automatiquement.")))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(t('سجل الأعطال', 'Historique des défauts'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      for (final r in rows)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(('${r['d']}').replaceFirst('T', '  '), style: const TextStyle(fontWeight: FontWeight.bold)),
                                if ((r['s'] as List).isEmpty && (r['p'] as List).isEmpty) Text(t('لا أعطال ✅', 'Aucun défaut ✅')),
                                for (final c in (r['s'] as List)) Text('$c — ${dtcExplain('$c')}'),
                                for (final c in (r['p'] as List)) Text('$c (${t('قيد الرصد', 'en attente')}) — ${dtcExplain('$c')}'),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _report() async {
    if (!await _need(Tier.pro)) return;
    if (stored == null) {
      _msg(t('اقرأ الأعطال أولاً', "Lisez d'abord les défauts"));
      return;
    }
    setState(() => busy = true);
    try {
      final bytes = await buildObdReportPdf(
        car: widget.store.car,
        stored: stored ?? [],
        pending: pending ?? [],
        live: live,
        odoKm: odoKm,
        adapter: adapterName,
      );
      await Printing.sharePdf(bytes: bytes, filename: 'obd_report.pdf');
    } catch (e) {
      _msg(t('تعذّر إنشاء التقرير: $e', 'Impossible de créer le rapport : $e'));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _clear() async {
    if (!await _need(Tier.pro)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('مسح الأعطال؟', 'Effacer les codes ?')),
        content: Text(t('سيُطفأ مصباح العطل وتُمسح الأكواد المخزنة. إن لم يُصلَح السبب سيعود العطل. هل تريد المتابعة؟',
            "Le voyant sera éteint et les codes effacés. Si la cause n'est pas réparée, le défaut reviendra. Continuer ?")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('إلغاء', 'Annuler'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('مسح', 'Effacer'))),
        ],
      ),
    );
    if (ok != true) return;
    await _stopLive();
    setState(() => busy = true);
    try {
      final done = await elm.clearDtcs();
      _msg(done ? t('تم المسح', 'Codes effacés') : t('لم تؤكد السيارة المسح', "La voiture n'a pas confirmé"));
      await _readDtcs();
    } catch (e) {
      _msg('$e');
    }
    if (mounted) setState(() => busy = false);
  }

  bool _liveOn = false;
  bool _liveBusy = false;

  Future<void> _stopLive() async {
    _liveOn = false;
    var n = 0;
    while (_liveBusy && n++ < 100) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  String _battNote(double? volts, double? rpmV) {
    if (volts == null) return '';
    final running = rpmV != null && rpmV > 400;
    if (running) {
      return volts < 13.0
          ? t(' ⚠️ الشحن ضعيف', ' ⚠️ charge faible')
          : volts > 14.9
              ? t(' ⚠️ مرتفع', ' ⚠️ élevée')
              : t(' ✅ الشحن سليم', ' ✅ charge OK');
    }
    return volts < 11.8
        ? t(' ⚠️ البطارية ضعيفة جداً', ' ⚠️ batterie très faible')
        : volts < 12.4
            ? t(' ⚠️ ضعيفة', ' ⚠️ faible')
            : t(' ✅ جيدة', ' ✅ bonne');
  }

  /// قراءة مباشرة متواصلة: تبدأ بضغطة وتتحدّث وحدها حتى الإيقاف
  Future<void> _readLive() async {
    if (_liveOn) {
      await _stopLive();
      if (mounted) setState(() {});
      return;
    }
    if (!await _need(Tier.pro)) return;
    _liveOn = true;
    _liveBusy = true;
    if (mounted) setState(() => status = '');
    var cycle = 0;
    double? rpmV;
    try {
      while (_liveOn && mounted && elm.connected) {
        final m = Map<String, String>.from(live);
        final rpm = await elm.pid('0C');
        if (rpm != null && rpm.length >= 2) {
          rpmV = (rpm[0] * 256 + rpm[1]) / 4;
          m[t('دوران المحرك', 'Régime')] = '${rpmV.round()} rpm';
        }
        if (!_liveOn) break;
        final sp = await elm.pid('0D');
        if (sp != null && sp.isNotEmpty) m[t('السرعة', 'Vitesse')] = '${sp[0]} km/h';
        final thr = await elm.pid('11');
        if (thr != null && thr.isNotEmpty) m[t('فتحة الخانق', 'Papillon')] = '${(thr[0] * 100 / 255).round()} %';
        final load = await elm.pid('04');
        if (load != null && load.isNotEmpty) m[t('حِمل المحرك', 'Charge moteur')] = '${(load[0] * 100 / 255).round()} %';
        // القيم البطيئة التغيّر: كل 5 دورات
        if (cycle % 5 == 0 && _liveOn) {
          final temp = await elm.pid('05');
          if (temp != null && temp.isNotEmpty) m[t('حرارة سائل التبريد', 'Liquide de refroidissement')] = '${temp[0] - 40} °C';
          final iat = await elm.pid('0F');
          if (iat != null && iat.isNotEmpty) m[t('حرارة هواء السحب', "Température d'air admission")] = '${iat[0] - 40} °C';
          final stft = await elm.pid('06');
          if (stft != null && stft.isNotEmpty) {
            m[t('تصحيح الوقود القصير', 'Correction carburant (court terme)')] = '${((stft[0] - 128) * 100 / 128).toStringAsFixed(1)} %';
          }
          final mil = await elm.pid('01');
          if (mil != null && mil.isNotEmpty) {
            final on = (mil[0] & 0x80) != 0;
            final n = mil[0] & 0x7F;
            m[t('مصباح العطل', 'Voyant moteur')] = on ? t('مضاء ($n أعطال)', 'Allumé ($n défauts)') : t('مطفأ', 'Éteint');
          }
          final v = await elm.cmd('ATRV');
          if (v.isNotEmpty) {
            final volts = double.tryParse(RegExp(r'[\d.]+').firstMatch(v.last)?.group(0) ?? '');
            m[t('جهد البطارية', 'Tension batterie')] = '${v.last}${_battNote(volts, rpmV)}';
          }
        }
        cycle++;
        if (!mounted) break;
        setState(() {
          live = m;
          if (m.isEmpty) status = t('لم تُرجع السيارة أي بيانات حية', "La voiture n'a renvoyé aucune donnée");
        });
        if (m.isEmpty) break;
        await Future.delayed(const Duration(milliseconds: 150));
      }
    } catch (e) {
      _msg('$e');
    }
    _liveOn = false;
    _liveBusy = false;
    if (mounted) setState(() {});
  }

  Future<void> _readOdo() async {
    if (!await _need(Tier.pro)) return;
    await _stopLive();
    setState(() => busy = true);
    try {
      final d = await elm.pid('A6');
      if (d != null && d.length >= 4) {
        final km = ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) / 10;
        if (!mounted) return;
        setState(() => odoKm = km.round().toString());
      } else {
        _msg(t('هذه السيارة لا تعطي العداد عبر OBD', "Cette voiture ne fournit pas le kilométrage via OBD"));
      }
    } catch (e) {
      _msg('$e');
    }
    if (mounted) setState(() => busy = false);
  }

  void _applyOdo() {
    final km = int.tryParse(odoKm ?? '');
    if (km == null) return;
    final car = widget.store.car;
    widget.store.updateCar(car, car.name, km, car.purchasePrice);
    _msg(t('تم تحديث العداد إلى $km كم', 'Compteur mis à jour : $km km'));
  }

  String _info() {
    final car = widget.store.car;
    return 'App: $appVersion\nCar ID: ${car.id}\nCar: ${car.label}\n'
        'Adapter: $adapterName\nELM: $elmVersion\nProtocol: $protocol\n'
        'Odometer via OBD: ${odoKm ?? '-'}\nLog:\n${elm.log.join('\n')}';
  }

  Widget _dtcList(String title, List<String> codes) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            if (codes.isEmpty)
              Text(t('لا توجد أعطال ✅', 'Aucun défaut ✅'))
            else
              for (final c in codes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(dtcExplain(c)),
                            if (dtcItemHint(c) != null && widget.store.car.itemById(dtcItemHint(c)!) != null)
                              TextButton.icon(
                                style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: AlignmentDirectional.centerStart),
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => ItemPage(store: widget.store, itemId: dtcItemHint(c)!))),
                                icon: const Icon(Icons.build_circle_outlined, size: 18),
                                label: Text(t('قد يتعلق بـ: ${widget.store.car.itemById(dtcItemHint(c)!)!.label}',
                                    'Peut concerner : ${widget.store.car.itemById(dtcItemHint(c)!)!.label}')),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: Lang.dir,
      child: Scaffold(
        appBar: AppBar(title: Text(t('فحص السيارة (OBD)', 'Diagnostic (OBD)'))),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: Icon(lic == null ? Icons.lock_outline : Icons.verified, color: lic == null ? null : Colors.green),
                title: Text(t('الاشتراك: ', 'Abonnement : ') + _licText()),
                subtitle: Text(t('أساسي: اتصال وقراءة الأعطال. كامل: + بيانات حية، مسح الأعطال، العداد.',
                    "De base : connexion et lecture des défauts. Complet : + données en direct, effacement, compteur.")),
                trailing: FilledButton.tonal(onPressed: _activateDialog, child: Text(t('تفعيل', 'Activer'))),
              ),
            ),
            if (lic != null && lic!.daysLeft <= 5)
              Card(
                color: Colors.orange.shade50,
                child: ListTile(
                  leading: const Icon(Icons.warning_amber, color: Colors.orange),
                  title: Text(lic!.daysLeft <= 0
                      ? t('ينتهي اشتراكك اليوم', "Votre abonnement expire aujourd'hui")
                      : t('ينتهي اشتراكك بعد ${lic!.daysLeft} أيام', "Votre abonnement expire dans ${lic!.daysLeft} jours")),
                  trailing: FilledButton(
                    onPressed: () => _whatsapp(widget.store.car, lic!.tier == Tier.pro),
                    child: Text(t('تجديد', 'Renouveler')),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Text(t(
                'ركّب محوّل ELM327 (بلوتوث) في فتحة OBD، وشغّل الاحتراق، ثم اقرنه من إعدادات البلوتوث في الهاتف. بعدها اضغط «عرض الأجهزة» واختره. القراءة تعمل دون إنترنت.',
                "Branchez l'adaptateur ELM327 (Bluetooth) sur la prise OBD, mettez le contact, puis associez-le dans les réglages Bluetooth. Appuyez ensuite sur « Afficher les appareils » et choisissez-le. Fonctionne sans internet.")),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : _loadDevices,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(t('عرض الأجهزة المقترنة', 'Afficher les appareils associés')),
            ),
            if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (status.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(status, style: const TextStyle(fontWeight: FontWeight.w600))),
            for (final d in devices)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: Text('${d.displayName}'),
                  subtitle: Text('${d.address}'),
                  onTap: busy ? null : () => _connect(d),
                ),
              ),
            if (ready) ...[
              const Divider(height: 32),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : _readDtcs,
                    icon: const Icon(Icons.search),
                    label: Text(t('قراءة الأعطال', 'Lire les défauts')),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : _readLive,
                    icon: Icon(_liveOn ? Icons.stop_circle_outlined : Icons.speed),
                    label: Text(_liveOn ? t('إيقاف البيانات الحية', 'Arrêter le direct') : t('بيانات حية', 'Données en direct')),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : _history,
                    icon: const Icon(Icons.history),
                    label: Text(t('سجل الأعطال', 'Historique')),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : _report,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: Text(t('تقرير PDF', 'Rapport PDF')),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: busy ? null : _readOdo,
                    icon: const Icon(Icons.pin),
                    label: Text(t('جلب العداد', 'Lire le compteur')),
                  ),
                ],
              ),
              if (stored != null) _dtcList(t('أعطال مخزّنة', 'Défauts enregistrés'), stored!),
              if (pending != null) _dtcList(t('أعطال قيد الرصد', 'Défauts en attente'), pending!),
              if (stored != null && stored!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _clear,
                    icon: const Icon(Icons.delete_sweep),
                    label: Text(t('مسح الأعطال', 'Effacer les défauts')),
                  ),
                ),
              if (live.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        for (final e in live.entries)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [Text(e.key), Text(e.value, style: const TextStyle(fontWeight: FontWeight.bold))],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (odoKm != null)
                Card(
                  child: ListTile(
                    title: Text(t('العداد من السيارة: $odoKm كم', 'Compteur lu : $odoKm km')),
                    trailing: FilledButton(onPressed: _applyOdo, child: Text(t('اعتمده', 'Utiliser'))),
                  ),
                ),
            ],
            const Divider(height: 32),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _info()));
                _msg(t('تم النسخ. الصقه في رسالة وأرسله لنا', 'Copié. Collez-le dans un message pour nous.'));
              },
              icon: const Icon(Icons.copy),
              label: Text(t('نسخ معلوماتي', 'Copier mes informations')),
            ),
          ],
        ),
      ),
    );
  }
}

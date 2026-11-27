import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'main.dart';

/// مستويات الاشتراك: أساسي = اتصال + قراءة الأعطال، كامل = الأساسي + بيانات حية + مسح الأعطال + العداد
enum Tier { none, basic, pro }

/// المفتاح العام فقط (التحقق من التوقيع). المفتاح السري عند المطوّر وحده.
const _pub = <int>[109,35,28,55,84,190,156,195,27,223,152,109,36,5,164,106,169,102,85,80,176,207,180,91,78,137,224,104,180,6,13,41];

final DateTime _epoch = DateTime.utc(2020, 1, 1);

class License {
  final Tier tier;
  final DateTime expiry; // يوم الانتهاء (شامل)
  final bool trial;
  const License(this.tier, this.expiry, {this.trial = false});

  /// الأيام المتبقية حتى الانتهاء (0 = ينتهي اليوم)
  int get daysLeft {
    final n = DateTime.now().toUtc();
    return expiry.difference(DateTime.utc(n.year, n.month, n.day)).inDays;
  }
}

/// مدة التجربة المجانية (اشتراك أساسي) لكل سيارة، مرة واحدة. ضع 0 لإيقافها.
const trialDays = 7;

/// رقم واتساب للطلب والتجديد
const waNumber = '213558494430';
Uri waUrl(String msg) => Uri.parse('https://wa.me/$waNumber?text=${Uri.encodeComponent(msg)}');

Uint8List _b64d(String s) {
  var x = s.replaceAll('-', '+').replaceAll('_', '/');
  while (x.length % 4 != 0) {
    x += '=';
  }
  return base64.decode(x);
}

/// يتحقق من كود: CC1.<payload>.<signature>، ويرجع الاشتراك إن كان صحيحاً ولهذه السيارة، وإلا null
Future<License?> parseLicense(String raw, String carId) async {
  try {
    final code = raw.replaceAll(RegExp(r'\s+'), '');
    final parts = code.split('.');
    if (parts.length != 3 || parts[0] != 'CC1') return null;
    final payload = _b64d(parts[1]);
    final sig = _b64d(parts[2]);
    if (payload.length < 5 || payload[0] != 1) return null;
    final ok = await Ed25519().verify(
      payload,
      signature: Signature(sig, publicKey: SimplePublicKey(_pub, type: KeyPairType.ed25519)),
    );
    if (!ok) return null;
    final id = utf8.decode(payload.sublist(4));
    if (id != carId) return null;
    final tier = payload[1] == 2 ? Tier.pro : (payload[1] == 1 ? Tier.basic : Tier.none);
    if (tier == Tier.none) return null;
    final days = (payload[2] << 8) | payload[3];
    return License(tier, _epoch.add(Duration(days: days)));
  } catch (_) {
    return null;
  }
}

String _key(Store s) => 'licenses';

Map<String, String> _loadAll(Store s) {
  try {
    final m = jsonDecode(s.prefs.getString(_key(s)) ?? '{}') as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {
    return {};
  }
}

/// يحفظ الكود بعد التحقق. يرجع الاشتراك أو null إذا كان الكود غير صالح لهذه السيارة
Future<License?> activateLicense(Store s, String carId, String code) async {
  final lic = await parseLicense(code, carId);
  if (lic == null) return null;
  final all = _loadAll(s);
  all[carId] = code.replaceAll(RegExp(r'\s+'), '');
  await s.prefs.setString(_key(s), jsonEncode(all));
  return lic;
}

Map<String, String> _loadTrials(Store s) {
  try {
    final m = jsonDecode(s.prefs.getString('trials') ?? '{}') as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {
    return {};
  }
}

/// هل يمكن بدء تجربة مجانية لهذه السيارة؟ (لم تُستعمل ولم يُفعَّل لها اشتراك من قبل)
bool canStartTrial(Store s, String carId) =>
    trialDays > 0 && !_loadTrials(s).containsKey(carId) && !_loadAll(s).containsKey(carId);

Future<License?> startTrial(Store s, String carId) async {
  if (!canStartTrial(s, carId)) return null;
  final now = DateTime.now().toUtc();
  final exp = DateTime.utc(now.year, now.month, now.day).add(const Duration(days: trialDays - 1));
  final m = _loadTrials(s);
  m[carId] = exp.toIso8601String().substring(0, 10);
  await s.prefs.setString('trials', jsonEncode(m));
  return License(Tier.basic, exp, trial: true);
}

/// الاشتراك الساري لهذه السيارة الآن (أو null). يمنع الرجوع بالساعة للخلف.
Future<License?> currentLicense(Store s, String carId) async {
  var now = DateTime.now().toUtc();
  final seen = s.prefs.getInt('licSeen') ?? 0;
  if (now.millisecondsSinceEpoch < seen) {
    now = DateTime.fromMillisecondsSinceEpoch(seen, isUtc: true);
  } else {
    await s.prefs.setInt('licSeen', now.millisecondsSinceEpoch);
  }
  final today = DateTime.utc(now.year, now.month, now.day);

  final code = _loadAll(s)[carId];
  if (code != null) {
    final lic = await parseLicense(code, carId);
    if (lic != null && !today.isAfter(lic.expiry)) return lic;
  }
  final tr = _loadTrials(s)[carId];
  if (tr != null) {
    final d = DateTime.tryParse(tr);
    if (d != null) {
      final exp = DateTime.utc(d.year, d.month, d.day);
      if (!today.isAfter(exp)) return License(Tier.basic, exp, trial: true);
    }
  }
  return null;
}

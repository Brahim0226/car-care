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
  const License(this.tier, this.expiry);
}

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

/// الاشتراك الساري لهذه السيارة الآن (أو null). يمنع الرجوع بالساعة للخلف.
Future<License?> currentLicense(Store s, String carId) async {
  final code = _loadAll(s)[carId];
  if (code == null) return null;
  final lic = await parseLicense(code, carId);
  if (lic == null) return null;
  var now = DateTime.now().toUtc();
  final seen = s.prefs.getInt('licSeen') ?? 0;
  if (now.millisecondsSinceEpoch < seen) {
    now = DateTime.fromMillisecondsSinceEpoch(seen, isUtc: true);
  } else {
    await s.prefs.setInt('licSeen', now.millisecondsSinceEpoch);
  }
  final today = DateTime.utc(now.year, now.month, now.day);
  if (today.isAfter(lic.expiry)) return null;
  return lic;
}

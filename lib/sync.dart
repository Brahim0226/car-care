import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'l10n.dart';
import 'main.dart';

/// المزامنة السحابية عبر Supabase (حساب بريد + كلمة سر). نسخة واحدة لكل مستخدم،
/// والأحدث (حسب modifiedAt) هو الذي يفوز.
late Cloud cloud;

const appVersion = '1.3.0';

/// عدّاد تثبيتات مجهول: رقم عشوائي + الإصدار + اللغة، مرة في اليوم كحد أقصى.
/// لا يُرسل أي اسم أو بيانات سيارة.
Future<void> pingInstall(Store store) async {
  try {
    final prefs = store.prefs;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (prefs.getString('lastPing') == today) return;
    var id = prefs.getString('installId');
    if (id == null) {
      final r = Random.secure();
      id = List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
      await prefs.setString('installId', id);
    }
    final res = await http
        .post(Uri.parse('${Cloud._url}/rest/v1/rpc/ping_install'),
            headers: {'apikey': Cloud._key, 'Content-Type': 'application/json'},
            body: jsonEncode({'p_id': id, 'p_version': appVersion, 'p_lang': Lang.code}))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      await prefs.setString('lastPing', today);
    }
  } catch (_) {}
}

class Cloud extends ChangeNotifier {
  static const _url = 'https://jkwtqpxpksucouksvjwo.supabase.co';
  static const _key = 'sb_publishable_3ndVRbf0bwdSlcqKx1awRg_ZJZjXk-X';

  final Store store;
  Map<String, dynamic>? _s;
  bool busy = false;
  String? lastMsg;
  Timer? _timer;
  bool _applying = false;
  int _pushedStamp = 0;

  Cloud(this.store) {
    try {
      final raw = store.prefs.getString('session');
      if (raw != null) _s = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    store.addListener(_onStore);
  }

  bool get loggedIn => _s != null;
  String get email => (_s?['email'] as String?) ?? '';

  Map<String, String> _h({String? token}) => {
        'apikey': _key,
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  String _err(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map) {
        final m = j['msg'] ?? j['error_description'] ?? j['message'] ?? j['error'];
        if (m != null) return m.toString();
      }
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }

  void _saveSession(Map<String, dynamic>? s) {
    _s = s;
    if (s == null) {
      store.prefs.remove('session');
    } else {
      store.prefs.setString('session', jsonEncode(s));
    }
    notifyListeners();
  }

  Map<String, dynamic>? _fromAuth(Map<String, dynamic> j, String email) {
    final at = j['access_token'] as String?;
    final rt = j['refresh_token'] as String?;
    final user = j['user'];
    if (at == null || rt == null || user is! Map) return null;
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 +
        ((j['expires_in'] as num?)?.toInt() ?? 3600);
    return {
      'access': at,
      'refresh': rt,
      'uid': user['id'],
      'email': email,
      'exp': exp,
    };
  }

  /// null = نجاح، وإلا نص الخطأ
  Future<String?> signIn(String email, String pass) async {
    try {
      final r = await http
          .post(Uri.parse('$_url/auth/v1/token?grant_type=password'),
              headers: _h(), body: jsonEncode({'email': email, 'password': pass}))
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return _err(r);
      final s = _fromAuth(jsonDecode(r.body) as Map<String, dynamic>, email);
      if (s == null) return t('رد غير متوقع من الخادم', "Réponse inattendue du serveur");
      _saveSession(s);
      return null;
    } catch (_) {
      return t('لا يوجد اتصال بالإنترنت', "Pas de connexion Internet");
    }
  }

  /// يرجع (نجاح، رسالة). إن لزم تأكيد البريد تكون الرسالة بذلك.
  Future<String?> signUp(String email, String pass) async {
    try {
      final r = await http
          .post(Uri.parse('$_url/auth/v1/signup'),
              headers: _h(), body: jsonEncode({'email': email, 'password': pass}))
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200 && r.statusCode != 201) return _err(r);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final s = _fromAuth(j, email);
      if (s != null) {
        _saveSession(s);
        return null;
      }
      return t('تم إنشاء الحساب. افتح بريدك وأكّد الرابط ثم سجّل الدخول.',
          "Compte créé. Ouvrez votre e-mail, confirmez le lien puis connectez-vous.");
    } catch (_) {
      return t('لا يوجد اتصال بالإنترنت', "Pas de connexion Internet");
    }
  }

  void signOut() {
    _timer?.cancel();
    _saveSession(null);
  }

  Future<String?> _token() async {
    final s = _s;
    if (s == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if ((s['exp'] as int) - now > 60) return s['access'] as String;
    try {
      final r = await http
          .post(Uri.parse('$_url/auth/v1/token?grant_type=refresh_token'),
              headers: _h(), body: jsonEncode({'refresh_token': s['refresh']}))
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) {
        if (r.statusCode == 400 || r.statusCode == 401) _saveSession(null);
        return null;
      }
      final n = _fromAuth(jsonDecode(r.body) as Map<String, dynamic>, email);
      if (n == null) return null;
      _saveSession(n);
      return n['access'] as String;
    } catch (_) {
      return null;
    }
  }

  void _onStore() {
    if (!loggedIn || _applying) return;
    if (store.modifiedAt <= _pushedStamp) return;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), () => _push());
  }

  Future<bool> _push() async {
    final tok = await _token();
    if (tok == null) return false;
    try {
      final stamp = store.modifiedAt;
      final r = await http
          .post(Uri.parse('$_url/rest/v1/app_backups?on_conflict=user_id'),
              headers: {
                ..._h(token: tok),
                'Prefer': 'resolution=merge-duplicates,return=minimal',
              },
              body: jsonEncode({
                'user_id': _s!['uid'],
                'data': jsonDecode(store.exportJson()),
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              }))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode >= 200 && r.statusCode < 300) {
        _pushedStamp = stamp;
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// مزامنة كاملة: يقارن النسخة المحلية بالسحابية ويأخذ الأحدث
  Future<String> syncNow() async {
    if (!loggedIn) return t('سجّل الدخول أولاً', "Connectez-vous d'abord");
    if (busy) return '';
    busy = true;
    notifyListeners();
    String msg;
    try {
      final tok = await _token();
      if (tok == null) {
        msg = t('تعذّر الاتصال أو انتهت الجلسة', "Connexion impossible ou session expirée");
      } else {
        final r = await http
            .get(
                Uri.parse(
                    '$_url/rest/v1/app_backups?select=data&user_id=eq.${_s!['uid']}'),
                headers: _h(token: tok))
            .timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) {
          msg = _err(r);
        } else {
          final rows = jsonDecode(r.body) as List;
          if (rows.isEmpty) {
            msg = await _push()
                ? t('تم رفع بياناتك إلى السحابة', "Données envoyées dans le cloud")
                : t('فشل الرفع', "Échec de l'envoi");
          } else {
            final remote = (rows.first as Map)['data'] as Map<String, dynamic>;
            final rs = (remote['modifiedAt'] as num?)?.toInt() ?? 0;
            if (rs > store.modifiedAt) {
              _applying = true;
              try {
                store.applyRemote(remote);
              } finally {
                _applying = false;
              }
              _pushedStamp = store.modifiedAt;
              msg = t('تم تحميل أحدث نسخة من السحابة', "Dernière version récupérée du cloud");
            } else if (rs == store.modifiedAt) {
              _pushedStamp = store.modifiedAt;
              msg = t('البيانات متطابقة', "Les données sont à jour");
            } else {
              msg = await _push()
                  ? t('تم رفع بياناتك إلى السحابة', "Données envoyées dans le cloud")
                  : t('فشل الرفع', "Échec de l'envoi");
            }
          }
        }
      }
    } catch (_) {
      msg = t('لا يوجد اتصال بالإنترنت', "Pas de connexion Internet");
    }
    busy = false;
    lastMsg = msg;
    notifyListeners();
    return msg;
  }
}

class CloudPage extends StatefulWidget {
  const CloudPage({super.key});

  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  final email = TextEditingController();
  final pass = TextEditingController();
  String? msg;
  bool working = false;

  @override
  void dispose() {
    email.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _go(bool create) async {
    final e = email.text.trim();
    final p = pass.text;
    if (!e.contains('@') || p.length < 6) {
      setState(() => msg = t('أدخل بريداً صحيحاً وكلمة سر من 6 أحرف على الأقل',
          "Saisissez un e-mail valide et un mot de passe de 6 caractères minimum"));
      return;
    }
    setState(() {
      working = true;
      msg = null;
    });
    final err = create ? await cloud.signUp(e, p) : await cloud.signIn(e, p);
    if (!mounted) return;
    setState(() {
      working = false;
      msg = err;
    });
    if (err == null && cloud.loggedIn) {
      final m = await cloud.syncNow();
      if (mounted) setState(() => msg = m);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cloud,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(t('المزامنة السحابية', "Synchronisation cloud"))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t('بياناتك تُحفظ نسخة في حسابك على خادم Supabase، فتجدها عند تغيير الهاتف. الصور (الفواتير) تبقى في الهاتف فقط.',
                    "Une copie de vos données est enregistrée dans votre compte sur le serveur Supabase, pour les retrouver si vous changez de téléphone. Les photos (factures) restent uniquement sur le téléphone."),
              ),
              const SizedBox(height: 16),
              if (!cloud.loggedIn) ...[
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                      labelText: t('البريد الإلكتروني', "E-mail"),
                      border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: InputDecoration(
                      labelText: t('كلمة السر', "Mot de passe"),
                      border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: working ? null : () => _go(false),
                  child: Text(t('تسجيل الدخول', "Se connecter")),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: working ? null : () => _go(true),
                  child: Text(t('إنشاء حساب جديد', "Créer un compte")),
                ),
              ] else ...[
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_done),
                    title: Text(cloud.email),
                    subtitle: Text(t('متصل', "Connecté")),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: cloud.busy
                      ? null
                      : () async {
                          final m = await cloud.syncNow();
                          if (mounted) setState(() => msg = m);
                        },
                  icon: const Icon(Icons.sync),
                  label: Text(t('مزامنة الآن', "Synchroniser maintenant")),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    cloud.signOut();
                    setState(() => msg = null);
                  },
                  child: Text(t('تسجيل الخروج', "Se déconnecter")),
                ),
              ],
              if (working || cloud.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (msg != null && msg!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(msg!),
                ),
            ],
          ),
        );
      },
    );
  }
}

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

const appVersion = '1.7.2';

/// نتيجة آخر فحص للتحديث (للتشخيص في «حول التطبيق»)
String updateDiag = '';

/// إحصائيات المشرف (تتطلب رمز المشرف، يتحقق منه الخادم)
Future<Map<String, dynamic>?> fetchInstallStats(String code) async {
  try {
    final r = await http
        .post(Uri.parse('${Cloud._url}/rest/v1/rpc/install_stats'),
            headers: {'apikey': Cloud._key, 'Content-Type': 'application/json'},
            body: jsonEncode({'p_code': code}))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    return jsonDecode(r.body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// هل الإصدار latest أحدث من الإصدار الحالي؟
bool isNewerVersion(String latest) {
  try {
    final l = latest.split('.').map(int.parse).toList();
    final c = appVersion.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }
  } catch (_) {}
  return false;
}

/// آخر إصدار منشور: من ملف version.txt المرفق بالإصدار (لا يخضع لحدود واجهة GitHub)، ثم من الواجهة كاحتياط
Future<String?> fetchLatestVersion() async {
  final re = RegExp(r'(\d+)\.(\d+)\.(\d+)');
  try {
    final r = await http
        .get(Uri.parse('https://github.com/Brahim0226/car-care/releases/latest/download/version.txt'))
        .timeout(const Duration(seconds: 12));
    updateDiag = 'github ${r.statusCode}';
    if (r.statusCode == 200) {
      final m = re.firstMatch(r.body);
      if (m != null) return '${m.group(1)}.${m.group(2)}.${m.group(3)}';
    }
  } catch (e) {
    updateDiag = 'github: ${e.toString().split('\n').first}';
  }
  try {
    final r = await http
        .get(Uri.parse('https://api.github.com/repos/Brahim0226/car-care/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 12));
    updateDiag += ' | api ${r.statusCode}';
    if (r.statusCode != 200) return null;
    final name = (jsonDecode(r.body) as Map<String, dynamic>)['name'] as String? ?? '';
    final m = RegExp(r'v(\d+)\.(\d+)\.(\d+)').firstMatch(name);
    if (m == null) return null;
    return '${m.group(1)}.${m.group(2)}.${m.group(3)}';
  } catch (e) {
    updateDiag += ' | api: ${e.toString().split('\n').first}';
    return null;
  }
}

/// يرجع رقم الإصدار الأحدث إن كان أكبر من الحالي، وإلا null
Future<String?> checkNewVersion() async {
  final v = await fetchLatestVersion();
  if (v != null && isNewerVersion(v)) return v;
  return null;
}

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

  /// يرسل رسالة استرجاع كلمة المرور إلى البريد
  Future<String?> sendReset(String email) async {
    try {
      final r = await http
          .post(Uri.parse('$_url/auth/v1/recover'),
              headers: _h(), body: jsonEncode({'email': email}))
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return _err(r);
      return null;
    } catch (_) {
      return t('لا يوجد اتصال بالإنترنت', "Pas de connexion Internet");
    }
  }

  /// يقبل رابط الرسالة كاملاً أو رمزاً رقمياً، ثم يضبط كلمة السر الجديدة ويسجّل الدخول
  Future<String?> resetWith(String input, String email, String newPass) async {
    try {
      final text = input.trim();
      String? accessToken;
      Map<String, dynamic>? body;
      final m = RegExp(r'https?://\S+').firstMatch(text);
      if (m != null) {
        final u = Uri.tryParse(m.group(0)!);
        if (u != null) {
          var frag = <String, String>{};
          try {
            frag = Uri.splitQueryString(u.fragment);
          } catch (_) {}
          final h = u.queryParameters['token_hash'] ?? u.queryParameters['token'];
          if (frag['access_token'] != null) {
            accessToken = frag['access_token'];
          } else if (h != null) {
            body = {'type': 'recovery', 'token_hash': h};
          }
        }
      } else if (RegExp(r'^\d{6,8}$').hasMatch(text)) {
        body = {'type': 'recovery', 'email': email, 'token': text};
      }
      if (accessToken == null) {
        if (body == null) {
          return t('الصق الرابط الذي وصلك بالبريد كاملاً أو الرمز الرقمي',
              "Collez le lien complet reçu par e-mail ou le code numérique");
        }
        final r = await http
            .post(Uri.parse('$_url/auth/v1/verify'),
                headers: _h(), body: jsonEncode(body))
            .timeout(const Duration(seconds: 25));
        if (r.statusCode != 200) {
          return t('الرابط أو الرمز غير صالح أو انتهت صلاحيته. اطلب رسالة جديدة.',
              "Lien ou code invalide ou expiré. Demandez un nouvel e-mail.");
        }
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        accessToken = j['access_token'] as String?;
        final s = _fromAuth(j, email);
        if (s != null) _s = s;
      }
      if (accessToken == null) {
        return t('رد غير متوقع من الخادم', "Réponse inattendue du serveur");
      }
      final u2 = await http
          .put(Uri.parse('$_url/auth/v1/user'),
              headers: _h(token: accessToken), body: jsonEncode({'password': newPass}))
          .timeout(const Duration(seconds: 25));
      if (u2.statusCode != 200) {
        _s = null;
        return _err(u2);
      }
      if (_s != null) _saveSession(_s);
      return null;
    } catch (_) {
      return t('لا يوجد اتصال بالإنترنت', "Pas de connexion Internet");
    }
  }

  Future<String?> changePassword(String newPass) async {
    final tok = await _token();
    if (tok == null) return t('انتهت الجلسة، سجّل الدخول من جديد', "Session expirée, reconnectez-vous");
    try {
      final r = await http
          .put(Uri.parse('$_url/auth/v1/user'),
              headers: _h(token: tok), body: jsonEncode({'password': newPass}))
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return _err(r);
      return null;
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

enum _Mode { signIn, signUp, forgot, reset }

class CloudPage extends StatefulWidget {
  const CloudPage({super.key});

  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  final email = TextEditingController();
  final pass = TextEditingController();
  final pass2 = TextEditingController();
  final code = TextEditingController();
  _Mode mode = _Mode.signIn;
  String? msg;
  bool ok = false;
  bool working = false;
  bool hide = true;

  @override
  void dispose() {
    email.dispose();
    pass.dispose();
    pass2.dispose();
    code.dispose();
    super.dispose();
  }

  void _go(_Mode m) {
    setState(() {
      mode = m;
      msg = null;
      pass.clear();
      pass2.clear();
      code.clear();
    });
  }

  bool _validEmail(String e) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e);

  void _fail(String m) => setState(() {
        msg = m;
        ok = false;
      });

  Future<void> _submit() async {
    final e = email.text.trim();
    final p = pass.text;
    if (!_validEmail(e)) {
      _fail(t('أدخل بريداً إلكترونياً صحيحاً', "Saisissez un e-mail valide"));
      return;
    }
    if (mode != _Mode.forgot && p.length < 6) {
      _fail(t('كلمة السر 6 أحرف على الأقل', "Le mot de passe doit avoir au moins 6 caractères"));
      return;
    }
    if ((mode == _Mode.signUp || mode == _Mode.reset) && p != pass2.text) {
      _fail(t('كلمتا السر غير متطابقتين', "Les mots de passe ne correspondent pas"));
      return;
    }
    setState(() {
      working = true;
      msg = null;
    });
    final cur = mode;
    String? err;
    String? info;
    switch (cur) {
      case _Mode.signIn:
        err = await cloud.signIn(e, p);
        break;
      case _Mode.signUp:
        err = await cloud.signUp(e, p);
        if (err != null && !cloud.loggedIn && err.contains(t('تم إنشاء', 'Compte créé'))) {
          info = err;
          err = null;
        }
        break;
      case _Mode.forgot:
        err = await cloud.sendReset(e);
        if (err == null) {
          info = t('أُرسلت رسالة إلى بريدك. افتحها ثم انسخ الرابط (اضغط مطولاً على الزر ← نسخ عنوان الرابط) والصقه في الخطوة التالية.',
              "Un e-mail a été envoyé. Ouvrez-le, copiez le lien (appui long sur le bouton → copier l'adresse du lien) et collez-le à l'étape suivante.");
          _mode2(_Mode.reset);
        }
        break;
      case _Mode.reset:
        err = await cloud.resetWith(code.text, e, p);
        if (err == null) {
          info = t('تم تغيير كلمة السر', "Mot de passe modifié");
        }
        break;
    }
    if (!mounted) return;
    setState(() {
      working = false;
      msg = err ?? info;
      ok = err == null;
    });
    if (err == null && cloud.loggedIn && (cur == _Mode.signIn || cur == _Mode.signUp)) {
      final m = await cloud.syncNow();
      if (mounted) setState(() => msg = m);
    } else if (err == null && cur == _Mode.reset) {
      if (!cloud.loggedIn) {
        _go(_Mode.signIn);
        setState(() {
          msg = info;
          ok = true;
        });
      } else {
        final m = await cloud.syncNow();
        if (mounted) setState(() => msg = m);
      }
    }
  }

  void _mode2(_Mode m) => mode = m;

  Future<void> _changePassDialog() async {
    final a = TextEditingController();
    final b = TextEditingController();
    String? err;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t('تغيير كلمة السر', "Changer le mot de passe")),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: a,
                obscureText: true,
                decoration: InputDecoration(labelText: t('كلمة السر الجديدة', "Nouveau mot de passe")),
              ),
              TextField(
                controller: b,
                obscureText: true,
                decoration: InputDecoration(labelText: t('أعد كتابتها', "Confirmer")),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(err!, style: const TextStyle(color: Colors.red)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('إلغاء', "Annuler"))),
            FilledButton(
              onPressed: () async {
                if (a.text.length < 6) {
                  setD(() => err = t('كلمة السر 6 أحرف على الأقل', "Au moins 6 caractères"));
                  return;
                }
                if (a.text != b.text) {
                  setD(() => err = t('كلمتا السر غير متطابقتين', "Les mots de passe ne correspondent pas"));
                  return;
                }
                final r = await cloud.changePassword(a.text);
                if (r != null) {
                  setD(() => err = r);
                  return;
                }
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  setState(() {
                    msg = t('تم تغيير كلمة السر', "Mot de passe modifié");
                    ok = true;
                  });
                }
              },
              child: Text(t('حفظ', "Enregistrer")),
            ),
          ],
        ),
      ),
    );
    a.dispose();
    b.dispose();
  }

  Widget _field(TextEditingController c, String label,
      {bool secret = false, TextInputType? type, int lines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: secret && hide,
        keyboardType: type,
        maxLines: secret ? 1 : lines,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: secret
              ? IconButton(
                  icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => hide = !hide),
                )
              : null,
        ),
      ),
    );
  }

  String get _title {
    switch (mode) {
      case _Mode.signIn:
        return t('تسجيل الدخول', "Connexion");
      case _Mode.signUp:
        return t('إنشاء حساب جديد', "Créer un compte");
      case _Mode.forgot:
        return t('نسيت كلمة السر', "Mot de passe oublié");
      case _Mode.reset:
        return t('كلمة سر جديدة', "Nouveau mot de passe");
    }
  }

  String get _action {
    switch (mode) {
      case _Mode.signIn:
        return t('دخول', "Se connecter");
      case _Mode.signUp:
        return t('إنشاء الحساب', "Créer le compte");
      case _Mode.forgot:
        return t('أرسل رسالة الاسترجاع', "Envoyer l'e-mail");
      case _Mode.reset:
        return t('حفظ كلمة السر الجديدة', "Enregistrer le mot de passe");
    }
  }

  List<Widget> _form() {
    return [
      Text(_title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      if (mode == _Mode.forgot)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(t('اكتب بريدك وسنرسل لك رسالة لتعيين كلمة سر جديدة.',
              "Saisissez votre e-mail : nous vous enverrons un message pour définir un nouveau mot de passe.")),
        ),
      _field(email, t('البريد الإلكتروني', "E-mail"), type: TextInputType.emailAddress),
      if (mode == _Mode.reset) ...[
        _field(code, t('الصق هنا الرابط الذي وصلك بالبريد (أو الرمز الرقمي)', "Collez ici le lien reçu par e-mail (ou le code)"), lines: 3),
        _field(pass, t('كلمة السر الجديدة', "Nouveau mot de passe"), secret: true),
        _field(pass2, t('أعد كتابة كلمة السر', "Confirmer le mot de passe"), secret: true),
      ] else if (mode != _Mode.forgot) ...[
        _field(pass, t('كلمة السر', "Mot de passe"), secret: true),
        if (mode == _Mode.signUp)
          _field(pass2, t('أعد كتابة كلمة السر', "Confirmer le mot de passe"), secret: true),
      ],
      FilledButton(onPressed: working ? null : _submit, child: Text(_action)),
      const SizedBox(height: 8),
      if (mode == _Mode.signIn) ...[
        TextButton(onPressed: () => _go(_Mode.forgot), child: Text(t('نسيت كلمة السر؟', "Mot de passe oublié ?"))),
        OutlinedButton(onPressed: () => _go(_Mode.signUp), child: Text(t('ليس عندي حساب: إنشاء حساب', "Pas de compte : en créer un"))),
      ] else ...[
        if (mode == _Mode.forgot)
          TextButton(onPressed: () => _go(_Mode.reset), child: Text(t('وصلتني الرسالة بالفعل', "J'ai déjà reçu l'e-mail"))),
        TextButton(onPressed: () => _go(_Mode.signIn), child: Text(t('رجوع إلى تسجيل الدخول', "Retour à la connexion"))),
      ],
    ];
  }

  List<Widget> _account() {
    return [
      Card(
        child: ListTile(
          leading: const Icon(Icons.account_circle, size: 36),
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
                if (mounted) {
                  setState(() {
                    msg = m;
                    ok = true;
                  });
                }
              },
        icon: const Icon(Icons.sync),
        label: Text(t('مزامنة الآن', "Synchroniser maintenant")),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _changePassDialog,
        icon: const Icon(Icons.lock_reset),
        label: Text(t('تغيير كلمة السر', "Changer le mot de passe")),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () {
          cloud.signOut();
          _go(_Mode.signIn);
        },
        icon: const Icon(Icons.logout),
        label: Text(t('تسجيل الخروج', "Se déconnecter")),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cloud,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(t('حسابي والمزامنة', "Mon compte et synchro"))),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                t('بياناتك تُحفظ نسخة في حسابك على خادم Supabase، فتجدها عند تغيير الهاتف. الصور (الفواتير) تبقى في الهاتف فقط.',
                    "Une copie de vos données est enregistrée dans votre compte sur le serveur Supabase, pour les retrouver si vous changez de téléphone. Les photos (factures) restent uniquement sur le téléphone."),
              ),
              const SizedBox(height: 16),
              ...(cloud.loggedIn ? _account() : _form()),
              if (working || cloud.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (msg != null && msg!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(msg!, style: TextStyle(color: ok ? Colors.green : Colors.red)),
                ),
            ],
          ),
        );
      },
    );
  }
}

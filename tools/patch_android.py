"""يعدّل مشروع أندرويد المولَّد تلقائياً ليدعم التنبيهات المجدولة.

- يفعّل core library desugaring (مطلوب لمكتبة flutter_local_notifications)
- يضيف الصلاحيات و receivers في AndroidManifest.xml
يعمل مع build.gradle.kts و build.gradle معاً. يفشل بوضوح إذا تغيّر شكل القالب.
"""
import os
import re
import sys

DESUGAR = "com.android.tools:desugar_jdk_libs:2.1.4"


STORE_PASS = os.environ.get("KEYSTORE_PASSWORD", "")
KEY_ALIAS = os.environ.get("KEY_ALIAS", "carcare")
if not STORE_PASS:
    sys.exit("KEYSTORE_PASSWORD غير موجود: أضف الأسرار في GitHub (Settings > Secrets > Actions)")

SIGN_KTS = """    signingConfigs {
        create("release") {
            storeFile = file("release.keystore")
            storePassword = "%s"
            keyAlias = "%s"
            keyPassword = "%s"
        }
    }
""" % (STORE_PASS, KEY_ALIAS, STORE_PASS)

SIGN_GROOVY = """    signingConfigs {
        release {
            storeFile file("release.keystore")
            storePassword "%s"
            keyAlias "%s"
            keyPassword "%s"
        }
    }
""" % (STORE_PASS, KEY_ALIAS, STORE_PASS)


def add_signing(src, is_kts):
    """توقيع ثابت (نفس المفتاح في كل بناء) كي يُثبَّت التحديث فوق النسخة القديمة."""
    if "release.keystore" in src:
        return src
    block = SIGN_KTS if is_kts else SIGN_GROOVY
    src, n = re.subn(r"(\n[ \t]*buildTypes\s*\{)", "\n" + block.rstrip("\n") + r"\1", src, count=1)
    if n != 1:
        sys.exit("لم أجد buildTypes لإضافة التوقيع")
    if is_kts:
        src, n = re.subn(r'signingConfigs\.getByName\("debug"\)', 'signingConfigs.getByName("release")', src)
    else:
        src, n = re.subn(r"signingConfigs\.debug", "signingConfigs.release", src)
    if n < 1:
        sys.exit("لم أجد سطر signingConfig الافتراضي لاستبداله")
    return src


def add_lint_off(src, is_kts):
    """lintVital ينهار (خلل في أداة Lint) عند بناء release، وهو غير ضروري لبناء APK."""
    if "checkReleaseBuilds" in src:
        return src
    blk = (
        "\n    lint {\n        checkReleaseBuilds = false\n        abortOnError = false\n    }"
        if is_kts
        else "\n    lint {\n        checkReleaseBuilds false\n        abortOnError false\n    }"
    )
    src, n = re.subn(r"(\nandroid\s*\{)", r"\1" + blk.replace("\\", "\\\\"), src, count=1)
    if n != 1:
        sys.exit("لم أجد كتلة android لتعطيل lint")
    return src


def patch_gradle(app_dir):
    kts = os.path.join(app_dir, "build.gradle.kts")
    groovy = os.path.join(app_dir, "build.gradle")
    if os.path.exists(kts):
        path, is_kts = kts, True
    elif os.path.exists(groovy):
        path, is_kts = groovy, False
    else:
        sys.exit("لم يوجد build.gradle(.kts) في " + app_dir)

    with open(path, encoding="utf-8") as f:
        src = f.read()

    if "coreLibraryDesugaring" in src:
        print("gradle: desugaring موجود مسبقاً")
        return

    flag = (
        "isCoreLibraryDesugaringEnabled = true"
        if is_kts
        else "coreLibraryDesugaringEnabled true"
    )
    new_src, n = re.subn(
        r"(compileOptions\s*\{)", r"\1\n        " + flag, src, count=1
    )
    if n != 1:
        sys.exit("لم أجد compileOptions في " + path)

    dep = (
        'coreLibraryDesugaring("%s")' % DESUGAR
        if is_kts
        else "coreLibraryDesugaring '%s'" % DESUGAR
    )
    if re.search(r"^dependencies\s*\{", new_src, flags=re.M):
        new_src = re.sub(
            r"^(dependencies\s*\{)", r"\1\n    " + dep, new_src, count=1, flags=re.M
        )
    else:
        new_src += "\ndependencies {\n    %s\n}\n" % dep

    new_src = add_signing(new_src, is_kts)
    new_src = add_lint_off(new_src, is_kts)

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_src)
    print("gradle: تم التعديل في", path)


PERMISSIONS = """    <uses-permission android:name="android.permission.INTERNET"/>
    <queries>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="geo"/></intent>
        <intent><action android:name="android.intent.action.INSERT"/><data android:mimeType="vnd.android.cursor.dir/event"/></intent>
    </queries>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
"""

RECEIVERS = """        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
"""


def widget_package(root):
    """يعيد (حزمة MainActivity, namespace) لتوليد مزوّد الودجت."""
    import glob
    import re

    pkg = None
    for f in glob.glob(os.path.join(root, "android", "app", "src", "main", "kotlin", "**", "MainActivity.kt"), recursive=True):
        m = re.search(r"^package\s+([\w.]+)", open(f, encoding="utf-8").read(), re.M)
        if m:
            pkg = m.group(1)
            kt_dir = os.path.dirname(f)
            break
    if not pkg:
        return None
    ns = pkg
    for g in ("build.gradle.kts", "build.gradle"):
        gp = os.path.join(root, "android", "app", g)
        if os.path.exists(gp):
            m = re.search(r"namespace\s*=?\s*[\"']([\w.]+)[\"']", open(gp, encoding="utf-8").read())
            if m:
                ns = m.group(1)
    return pkg, ns, kt_dir


def copy_widget(root):
    """ينسخ ملفات الودجت (layout/xml/drawable + مزوّد Kotlin) إلى مشروع أندرويد."""
    import shutil

    src = os.path.join(root, "android-widget")
    if not os.path.isdir(src):
        print("widget: لا يوجد android-widget")
        return None
    info = widget_package(root)
    if not info:
        print("widget: لم أجد MainActivity.kt، تخطّي الودجت")
        return None
    pkg, ns, kt_dir = info
    res = os.path.join(root, "android", "app", "src", "main", "res")
    for sub in ("layout", "xml", "drawable"):
        os.makedirs(os.path.join(res, sub), exist_ok=True)
        d = os.path.join(src, "res", sub)
        for f in os.listdir(d):
            shutil.copy(os.path.join(d, f), os.path.join(res, sub, f))
    tpl = open(os.path.join(src, "CarWidgetProvider.kt.tpl"), encoding="utf-8").read()
    kt = tpl.replace("__PKG__", pkg).replace("__NS__", ns)
    with open(os.path.join(kt_dir, "CarWidgetProvider.kt"), "w", encoding="utf-8") as f:
        f.write(kt)
    print("widget: تم النسخ، الحزمة", pkg, "namespace", ns)
    return pkg


def patch_manifest(path, widget_pkg=None):
    with open(path, encoding="utf-8") as f:
        src = f.read()

    if "ScheduledNotificationReceiver" in src:
        print("manifest: معدّل مسبقاً")
        return
    if "<application" not in src or "</application>" not in src:
        sys.exit("شكل AndroidManifest غير متوقع")

    src = src.replace("<application", PERMISSIONS + "    <application", 1)
    extra = ""
    if widget_pkg:
        extra = (
            '        <receiver android:name="%s.CarWidgetProvider" android:exported="true">\n'
            '            <intent-filter>\n'
            '                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />\n'
            '            </intent-filter>\n'
            '            <meta-data android:name="android.appwidget.provider" android:resource="@xml/car_widget_info" />\n'
            '        </receiver>\n'
        ) % widget_pkg
    src = src.replace("</application>", RECEIVERS + extra + "    </application>", 1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("manifest: تم التعديل")


ROOT_KTS = """
// fixSdk36: بعض الإضافات مبنية على compileSdk أقدم من المطلوب في اعتمادياتها
subprojects {
    fun fixSdk(p: Project) {
        val ext = p.extensions.findByName("android") ?: return
        ext.javaClass.methods
            .filter { it.name == "setCompileSdk" && it.parameterCount == 1 }
            .forEach {
                try {
                    it.invoke(ext, 36)
                } catch (e: Exception) {
                }
            }
    }
    if (state.executed) fixSdk(this) else afterEvaluate { fixSdk(this) }
}
"""

ROOT_GROOVY = """
// fixSdk36
subprojects { p ->
    def fix = {
        if (p.hasProperty('android')) { p.android.compileSdk = 36 }
    }
    if (p.state.executed) { fix() } else { p.afterEvaluate { fix() } }
}
"""


def patch_root(root):
    kts = os.path.join(root, "android", "build.gradle.kts")
    groovy = os.path.join(root, "android", "build.gradle")
    if os.path.exists(kts):
        path, add = kts, ROOT_KTS
    elif os.path.exists(groovy):
        path, add = groovy, ROOT_GROOVY
    else:
        sys.exit("لم يوجد android/build.gradle(.kts)")
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if "fixSdk36" in src:
        return
    with open(path, "a", encoding="utf-8") as f:
        f.write(add)
    print("root gradle: تم رفع compileSdk للإضافات في", path)


def copy_icons(root):
    """يستبدل أيقونة Flutter الافتراضية بأيقونة التطبيق (مجلد android-res)."""
    import shutil

    src = os.path.join(root, "android-res")
    dst = os.path.join(root, "android", "app", "src", "main", "res")
    if not os.path.isdir(src):
        print("icons: لا يوجد android-res")
        return
    for d in os.listdir(src):
        f = os.path.join(src, d, "ic_launcher.png")
        if os.path.isfile(f) and os.path.isdir(os.path.join(dst, d)):
            shutil.copy(f, os.path.join(dst, d, "ic_launcher.png"))
    print("icons: تم النسخ")


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    patch_gradle(os.path.join(root, "android", "app"))
    wpkg = copy_widget(root)
    patch_manifest(
        os.path.join(root, "android", "app", "src", "main", "AndroidManifest.xml"), wpkg
    )
    patch_root(root)
    copy_icons(root)

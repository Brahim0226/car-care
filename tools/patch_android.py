"""يعدّل مشروع أندرويد المولَّد تلقائياً ليدعم التنبيهات المجدولة.

- يفعّل core library desugaring (مطلوب لمكتبة flutter_local_notifications)
- يضيف الصلاحيات و receivers في AndroidManifest.xml
يعمل مع build.gradle.kts و build.gradle معاً. يفشل بوضوح إذا تغيّر شكل القالب.
"""
import os
import re
import sys

DESUGAR = "com.android.tools:desugar_jdk_libs:2.1.4"


STORE_PASS = "carcare2026"
KEY_ALIAS = "carcare"

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


def patch_manifest(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()

    if "ScheduledNotificationReceiver" in src:
        print("manifest: معدّل مسبقاً")
        return
    if "<application" not in src or "</application>" not in src:
        sys.exit("شكل AndroidManifest غير متوقع")

    src = src.replace("<application", PERMISSIONS + "    <application", 1)
    src = src.replace("</application>", RECEIVERS + "    </application>", 1)

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print("manifest: تم التعديل")


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    patch_gradle(os.path.join(root, "android", "app"))
    patch_manifest(
        os.path.join(root, "android", "app", "src", "main", "AndroidManifest.xml")
    )

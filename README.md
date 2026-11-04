# تطبيق إدارة ميكروتك (اتصال مباشر عبر RouterOS API)

الدخول: عنوان الراوتر + منفذ API + اسم المستخدم + كلمة المرور.
- المنفذ الافتراضي 8728 (api)، أو 8729 مع تفعيل خيار الاتصال المشفّر (api-ssl).
- يتطلب RouterOS 6.43 أو أحدث (تسجيل الدخول بكلمة المرور مباشرة).

## على الراوتر
```
/ip service enable api
```
ولا تنسَ السماح لعنوان الموبايل في `address` الخاص بالخدمة إن كنت قد قيّدته.

## البناء (الأسهل: GitHub Actions)
ارفع المجلد إلى مستودع GitHub ← تبويب Actions ← Build APK ← Run workflow ← نزّل `mikrotik-apk`.

## البناء على جهازك
1. `flutter create mikrotik_app` ثم انسخ `lib/main.dart` و `pubspec.yaml` فوق ملفات المشروع.
2. في `android/app/src/main/AndroidManifest.xml` أضف قبل وسم `<application`:
   `<uses-permission android:name="android.permission.INTERNET"/>`
3. `flutter pub get` ثم `flutter build apk --release`

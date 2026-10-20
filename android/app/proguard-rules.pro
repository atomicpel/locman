# Ядро Xray вызывается через рефлексию, TUN-мост — через JNI.
-keep class libv2ray.** { *; }
-keep class go.** { *; }
-keep class hev.sockstun.** { *; }
-keep class app.locman.** { *; }
-dontwarn libv2ray.**
-dontwarn go.**

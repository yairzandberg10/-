package com.ogen.app;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.provider.Telephony;
import android.telecom.TelecomManager;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;

import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/** Which packages / screens are allowed, blocked or protected. */
public final class Rules {
    private Rules() {}

    public static final String MOOVIT = "com.tranzmate";

    /** Always allowed: telephony, messaging, contacts, system UI, Moovit. Fails open for anything phone related. */
    private static final Set<String> BASE_ALLOWED = new HashSet<>(Arrays.asList(
            "android", "com.android.systemui",
            "com.android.phone", "com.android.server.telecom", "com.android.incallui",
            "com.android.dialer", "com.google.android.dialer", "com.samsung.android.dialer",
            "com.android.emergency", "com.google.android.apps.safetyhub",
            "com.android.stk", "com.android.cellbroadcastreceiver", "com.google.android.cellbroadcastreceiver",
            "com.android.mms", "com.android.messaging", "com.google.android.apps.messaging",
            "com.android.contacts", "com.google.android.contacts",
            "com.android.permissioncontroller", "com.google.android.permissioncontroller",
            "com.android.providers.telephony", "com.android.simappdialog",
            MOOVIT));

    private static final Set<String> STORES = new HashSet<>(Arrays.asList(
            "com.android.packageinstaller", "com.google.android.packageinstaller",
            "com.miui.packageinstaller", "com.samsung.android.packageinstaller",
            "com.android.vending", "com.aurora.store", "org.fdroid.fdroid", "com.apkpure.aegon",
            "com.uptodown", "com.huawei.appmarket", "com.xiaomi.market", "com.xiaomi.mipicks",
            "com.sec.android.app.samsungapps", "com.amazon.venezia", "com.qooapp.qoohelper",
            "com.bbk.appstore", "com.heytap.market", "com.oppo.market", "com.tencent.android.qqdownloader",
            "com.baidu.appsearch", "com.wandoujia.phoenix2", "com.qihoo.appstore", "com.duoqin.appstore"));

    private static final Set<String> SOCIAL = new HashSet<>(Arrays.asList(
            "com.instagram.android", "com.instagram.lite", "com.instagram.barcelona",
            "com.zhiliaoapp.musically", "com.ss.android.ugc.trill", "com.zhiliaoapp.musically.go",
            "com.ss.android.ugc.aweme", "com.smile.gifmaker", "tv.danmaku.bili",
            "com.facebook.katana", "com.facebook.lite", "com.twitter.android", "com.snapchat.android",
            "com.google.android.youtube", "com.google.android.apps.youtube.kids", "app.revanced.android.youtube",
            "com.vanced.android.youtube", "org.schabi.newpipe", "free.rm.skytube.oss",
            "com.reddit.frontpage", "com.pinterest", "com.netflix.mediaclient", "tv.twitch.android.app",
            "com.tumblr", "com.linkedin.android", "com.ninegag.android.app", "com.kwai.video",
            "com.google.android.youtube.tv", "com.disney.disneyplus", "com.amazon.avod.thirdpartyclient"));

    private static final String[] SITES = {
            "youtube.com", "youtu.be", "instagram.com", "tiktok.com", "facebook.com", "fb.com", "fb.watch",
            "x.com", "twitter.com", "reddit.com", "netflix.com", "twitch.tv", "pinterest.com", "snapchat.com",
            "9gag.com", "threads.net", "tumblr.com", "bilibili.com", "douyin.com", "kick.com", "vimeo.com",
            "dailymotion.com", "linkedin.com"
    };

    private static final String[] BROWSERS = {
            "com.android.chrome", "com.chrome.beta", "com.chrome.dev", "org.mozilla.firefox", "org.mozilla.focus",
            "org.mozilla.fenix", "com.opera.browser", "com.opera.mini.native", "com.opera.gx", "com.brave.browser",
            "com.microsoft.emmx", "com.sec.android.app.sbrowser", "com.UCMobile.intl", "com.uc.browser.en",
            "com.duckduckgo.mobile.android", "com.kiwibrowser.browser", "com.vivaldi.browser", "com.android.browser",
            "com.mi.globalbrowser", "com.yandex.browser", "mark.via.gp", "mark.via", "com.mx.browser"
    };

    private static Set<String> dynamicAllowed;
    private static Set<String> dynamicBrowsers;
    private static long dynamicAt;

    /** Recomputed every ~30s: default dialer/SMS, launchers, keyboards (all must keep working). */
    private static synchronized void refresh(Context c) {
        long t = android.os.SystemClock.elapsedRealtime();
        if (dynamicAllowed != null && t - dynamicAt < 30_000) return;
        dynamicAt = t;
        Set<String> s = new HashSet<>();
        s.add(c.getPackageName());
        PackageManager pm = c.getPackageManager();
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                TelecomManager tm = (TelecomManager) c.getSystemService(Context.TELECOM_SERVICE);
                if (tm != null && tm.getDefaultDialerPackage() != null) s.add(tm.getDefaultDialerPackage());
            }
        } catch (RuntimeException ignored) { }
        try {
            String sms = Telephony.Sms.getDefaultSmsPackage(c);
            if (sms != null) s.add(sms);
        } catch (RuntimeException ignored) { }
        addResolvers(pm, s, new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME));
        addResolvers(pm, s, new Intent(Intent.ACTION_DIAL));
        addResolvers(pm, s, new Intent(Intent.ACTION_DIAL, Uri.parse("tel:123")));
        addResolvers(pm, s, new Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:123")));
        try {
            InputMethodManager imm = (InputMethodManager) c.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) for (InputMethodInfo i : imm.getEnabledInputMethodList()) s.add(i.getPackageName());
        } catch (RuntimeException ignored) { }
        try {
            String cur = Settings.Secure.getString(c.getContentResolver(), Settings.Secure.DEFAULT_INPUT_METHOD);
            if (cur != null) s.add(ComponentName.unflattenFromString(cur).getPackageName());
        } catch (RuntimeException ignored) { }
        // Settings registers a fallback HOME activity; it must never be whitelisted this way.
        s.remove("com.android.settings");
        s.removeAll(STORES);
        dynamicAllowed = s;

        Set<String> b = new HashSet<>(Arrays.asList(BROWSERS));
        Set<String> tmp = new HashSet<>();
        addResolvers(pm, tmp, new Intent(Intent.ACTION_VIEW, Uri.parse("http://example.com")));
        b.addAll(tmp);
        dynamicBrowsers = b;
    }

    private static void addResolvers(PackageManager pm, Set<String> out, Intent i) {
        try {
            int flags = Build.VERSION.SDK_INT >= 23 ? PackageManager.MATCH_ALL : 0;
            List<ResolveInfo> r = pm.queryIntentActivities(i, flags);
            for (ResolveInfo ri : r) if (ri.activityInfo != null) out.add(ri.activityInfo.packageName);
        } catch (RuntimeException ignored) { }
    }

    /** Usable during a full lockdown. */
    public static boolean allowedInLock(Context c, Policy p, String pkg) {
        if (pkg == null) return true;
        refresh(c);
        return BASE_ALLOWED.contains(pkg) || dynamicAllowed.contains(pkg) || p.extraAllowed.contains(pkg)
                || pkg.startsWith("com.android.incallui") || pkg.endsWith(".incallui")
                || pkg.contains("dialer") || pkg.contains("telecom");
    }

    /** Doesn't count toward the daily allowance. */
    public static boolean free(Context c, Policy p, String pkg) {
        return allowedInLock(c, p, pkg);
    }

    public static boolean isStore(String pkg, String cls) {
        if (pkg == null || !STORES.contains(pkg)) return false;
        // runtime-permission dialogs live in the installer package on older Android
        return cls == null || !cls.contains("GrantPermissions");
    }

    public static boolean isSocial(String pkg) {
        return pkg != null && SOCIAL.contains(pkg);
    }

    public static boolean isBrowser(Context c, String pkg) {
        if (pkg == null) return false;
        refresh(c);
        return dynamicBrowsers.contains(pkg);
    }

    public static boolean isSettings(String pkg) {
        return "com.android.settings".equals(pkg) || "com.android.settings.intelligence".equals(pkg)
                || "com.miui.securitycenter".equals(pkg) || "com.coloros.safecenter".equals(pkg);
    }

    private static final String[] TAMPER_CLASSES = {
            "DeviceAdmin", "Accessibility", "DateTime", "Development", "MasterClear", "FactoryReset",
            "ResetDashboard", "InstalledAppDetails", "AppInfo", "ManageApplications", "RunningServices",
            "UsageAccess", "RestrictedSettings", "DefaultHome", "Uninstall"
    };

    private static final String[] TAMPER_TEXT = {
            "עוגן", "Ogen",
            "date & time", "date and time", "תאריך ושעה", "日期和时间", "日期與時間",
            "developer options", "אפשרויות למפתחים", "开发者选项", "usb debugging", "ניפוי באגים",
            "factory reset", "erase all data", "איפוס להגדרות היצרן", "恢复出厂设置",
            "device admin", "מנהלי מכשיר", "אפליקציות לניהול המכשיר", "设备管理"
    };

    public static boolean tamperClass(String cls) {
        if (cls == null) return false;
        for (String t : TAMPER_CLASSES) if (cls.contains(t)) return true;
        return false;
    }

    /** Text visible in a Settings window that means it could be used to escape. */
    public static boolean tamperText(String lowerText) {
        for (String t : TAMPER_TEXT) if (lowerText.contains(t.toLowerCase(Locale.ROOT))) return true;
        return false;
    }

    /** Does a URL-bar text point to a blocked site? */
    public static boolean blockedUrl(String text) {
        if (text == null) return false;
        String s = text.trim().toLowerCase(Locale.ROOT);
        if (s.isEmpty() || s.contains(" ")) return false;
        int i = s.indexOf("://");
        if (i >= 0) s = s.substring(i + 3);
        int end = s.length();
        for (char ch : new char[]{'/', '?', '#', ':'}) {
            int j = s.indexOf(ch);
            if (j >= 0 && j < end) end = j;
        }
        String host = s.substring(0, end);
        for (String d : SITES) if (host.equals(d) || host.endsWith("." + d)) return true;
        return false;
    }
}

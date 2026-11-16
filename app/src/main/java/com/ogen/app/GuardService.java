package com.ogen.app;

import android.accessibilityservice.AccessibilityService;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.List;
import java.util.Locale;

/**
 * The enforcer. Watches which app is in front, counts screen time, and sends you
 * home whenever you open something the current commitment does not allow.
 */
public class GuardService extends AccessibilityService {

    private static final long TICK = 5_000L;
    private static volatile boolean running;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private String foreground;
    private String foregroundClass;
    private long lastTickEl;
    private long lastBlockEl;
    private long lastScanEl;
    private PowerManager power;

    public static boolean isRunning() {
        return running;
    }

    private final Runnable ticker = new Runnable() {
        @Override public void run() {
            try { tick(); } catch (RuntimeException ignored) { }
            handler.postDelayed(this, TICK);
        }
    };

    private final BroadcastReceiver screenReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            // screen on/off or clock change: settle accounting immediately
            lastTickEl = SystemClock.elapsedRealtime();
            Store.now(c);
        }
    };

    @Override protected void onServiceConnected() {
        super.onServiceConnected();
        running = true;
        power = (PowerManager) getSystemService(POWER_SERVICE);
        lastTickEl = SystemClock.elapsedRealtime();
        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_SCREEN_ON);
        f.addAction(Intent.ACTION_SCREEN_OFF);
        f.addAction(Intent.ACTION_TIME_CHANGED);
        f.addAction(Intent.ACTION_TIMEZONE_CHANGED);
        registerReceiver(screenReceiver, f);
        handler.post(ticker);
    }

    @Override public void onDestroy() {
        running = false;
        handler.removeCallbacks(ticker);
        try { unregisterReceiver(screenReceiver); } catch (RuntimeException ignored) { }
        super.onDestroy();
    }

    @Override public void onInterrupt() { }

    @Override public void onAccessibilityEvent(AccessibilityEvent e) {
        try {
            handle(e);
        } catch (RuntimeException ignored) {
            // never let one odd event kill enforcement
        }
    }

    private void handle(AccessibilityEvent e) {
        if (e == null || e.getPackageName() == null) return;
        String pkg = e.getPackageName().toString();
        String cls = e.getClassName() == null ? null : e.getClassName().toString();
        int type = e.getEventType();

        if (type == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            if (!isOverlayPackage(pkg)) {
                foreground = pkg;
                foregroundClass = cls;
            }
            evaluate(pkg, cls, true);
            if (Rules.isSettings(pkg)) {
                // Settings pages fill in their content after the window opens: look again shortly
                for (long d : new long[]{300, 800, 1600, 3000}) {
                    handler.postDelayed(() -> {
                        try {
                            String cur = currentPackage();
                            if (cur != null && Rules.isSettings(cur)) evaluate(cur, foregroundClass, false);
                        } catch (RuntimeException ignored) { }
                    }, d);
                }
            }
        } else if (type == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED
                || type == AccessibilityEvent.TYPE_VIEW_SCROLLED) {
            long el = SystemClock.elapsedRealtime();
            if (el - lastScanEl < 700) return;
            lastScanEl = el;
            evaluate(pkg, cls, false);
        }
    }

    /** Keyboards and system UI float above apps; they don't change "which app you are in". */
    private boolean isOverlayPackage(String pkg) {
        return "com.android.systemui".equals(pkg) || (Rules.allowedInLock(this, Store.policy(this), pkg)
                && !pkg.equals(getPackageName()) && isKeyboard(pkg));
    }

    private boolean isKeyboard(String pkg) {
        String p = pkg.toLowerCase(Locale.ROOT);
        return p.contains("inputmethod") || p.contains("keyboard") || p.contains("ime");
    }

    private void tick() {
        long el = SystemClock.elapsedRealtime();
        long delta = el - lastTickEl;
        lastTickEl = el;
        Policy p = Store.policy(this);
        long now = Store.now(this);
        boolean changed = p.tick(now);

        boolean screenOn = power == null || (Build.VERSION.SDK_INT >= 20 ? power.isInteractive() : power.isScreenOn());
        String pkg = currentPackage();
        if (screenOn && delta > 0 && delta < 3 * TICK && pkg != null && p.limitMs != Policy.NONE
                && !p.locked(now) && !Rules.free(this, p, pkg)) {
            p.addUsage(delta, now);
            changed = true;
        }
        if (changed) Store.save(this);
        if (screenOn && pkg != null) evaluate(pkg, foregroundClass, false);
    }

    private String currentPackage() {
        try {
            AccessibilityNodeInfo root = getRootInActiveWindow();
            if (root != null && root.getPackageName() != null) {
                String p = root.getPackageName().toString();
                if (!isOverlayPackage(p)) return p;
            }
        } catch (RuntimeException ignored) { }
        return foreground;
    }

    /** Decide whether the window in front must be closed. */
    private void evaluate(String pkg, String cls, boolean stateChange) {
        if (pkg.equals(getPackageName())) return;
        Policy p = Store.policy(this);
        long now = Store.now(this);
        if (p.tick(now)) Store.save(this);
        if (!p.guarding(now)) return;

        boolean committed = p.committed(now);
        boolean locked = p.locked(now);

        // 1. Settings: fully closed during a lockdown; escape routes closed otherwise.
        if (Rules.isSettings(pkg)) {
            // turning protection ON is always fine, even mid-commitment
            String screen = stateChange ? cls : foregroundClass;
            if (screen != null && screen.contains("DeviceAdminAdd") && !adminActive()) return;
            if (locked) { block(BlockActivity.R_LOCKED, true); return; }
            if (Rules.tamperClass(screen) || settingsTextIsTamper()) { block(BlockActivity.R_TAMPER, true, pkg); }
            return;
        }

        // 2. Installing / uninstalling apps is off while any commitment is active.
        String activity = stateChange ? cls : foregroundClass;
        if (committed && Rules.isStore(pkg, activity) && !isSelfUpdate(pkg, activity)) {
            block(BlockActivity.R_STORE, true, pkg);
            return;
        }

        // 3. Full lockdown: only calls, messages, Moovit and approved apps.
        if (locked) {
            if (!Rules.allowedInLock(this, p, pkg)) block(BlockActivity.R_LOCKED, stateChange, pkg);
            return;
        }

        // 4. Free time, but social / video stays off.
        if (p.socialBlock) {
            if (Rules.isSocial(pkg)) { block(BlockActivity.R_SOCIAL, stateChange, pkg); return; }
            if (Rules.isBrowser(this, pkg) && browserOnBlockedSite()) block(BlockActivity.R_SITE, true);
        }
    }

    /** The system installer showing an update of Ogen itself (never an uninstall) is allowed. */
    private boolean isSelfUpdate(String pkg, String activity) {
        if (!pkg.contains("packageinstaller")) return false;
        if (activity != null && activity.contains("Uninstall")) return false;
        AccessibilityNodeInfo root;
        try { root = getRootInActiveWindow(); } catch (RuntimeException e) { return false; }
        if (root == null) return false;
        StringBuilder sb = new StringBuilder();
        collectText(root, sb, 0, new int[]{0});
        String t = sb.toString().toLowerCase(Locale.ROOT);
        if (t.contains("uninstall") || t.contains("להסיר") || t.contains("הסרת") || t.contains("卸载")) return false;
        return t.contains("עוגן") || t.contains("ogen");
    }

    private boolean adminActive() {
        android.app.admin.DevicePolicyManager dpm =
                (android.app.admin.DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
        return dpm != null && dpm.isAdminActive(new android.content.ComponentName(this, AdminReceiver.class));
    }

    private boolean settingsTextIsTamper() {
        AccessibilityNodeInfo root;
        try { root = getRootInActiveWindow(); } catch (RuntimeException e) { return false; }
        if (root == null) return false;
        StringBuilder sb = new StringBuilder();
        collectText(root, sb, 0, new int[]{0});
        return Rules.tamperText(sb.toString().toLowerCase(Locale.ROOT));
    }

    private void collectText(AccessibilityNodeInfo n, StringBuilder sb, int depth, int[] count) {
        if (n == null || depth > 30 || count[0] > 400) return;
        count[0]++;
        CharSequence t = n.getText();
        if (t != null) sb.append(t).append('\n');
        CharSequence d = n.getContentDescription();
        if (d != null) sb.append(d).append('\n');
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo ch;
            try { ch = n.getChild(i); } catch (RuntimeException e) { continue; }
            collectText(ch, sb, depth + 1, count);
        }
    }

    private static final String[] URL_BAR_IDS = {
            ":id/url_bar", ":id/mozac_browser_toolbar_url_view", ":id/url_field", ":id/location_bar_edit_text",
            ":id/search_box", ":id/address_bar_edit_text", ":id/url", ":id/addressbarEdit", ":id/omnibarTextInput",
            ":id/sbrowser_url_bar", ":id/location_bar", ":id/url_edit", ":id/edit_text"
    };

    private boolean browserOnBlockedSite() {
        AccessibilityNodeInfo root;
        try { root = getRootInActiveWindow(); } catch (RuntimeException e) { return false; }
        if (root == null || root.getPackageName() == null) return false;
        String pkg = root.getPackageName().toString();
        for (String id : URL_BAR_IDS) {
            List<AccessibilityNodeInfo> nodes;
            try { nodes = root.findAccessibilityNodeInfosByViewId(pkg + id); } catch (RuntimeException e) { continue; }
            if (nodes == null) continue;
            for (AccessibilityNodeInfo n : nodes) {
                if (n != null && n.getText() != null && Rules.blockedUrl(n.getText().toString())) return true;
            }
        }
        // Fallback: any short single-token text that looks like a blocked address (title bars, tabs).
        return scanForUrl(root, 0, new int[]{0});
    }

    private boolean scanForUrl(AccessibilityNodeInfo n, int depth, int[] count) {
        if (n == null || depth > 12 || count[0] > 150) return false;
        count[0]++;
        CharSequence t = n.getText();
        if (t != null && t.length() < 300 && n.isEditable() && Rules.blockedUrl(t.toString())) return true;
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo ch;
            try { ch = n.getChild(i); } catch (RuntimeException e) { continue; }
            if (scanForUrl(ch, depth + 1, count)) return true;
        }
        return false;
    }

    private void block(int reason, boolean force) {
        block(reason, force, null);
    }

    private void block(int reason, boolean force, String blockedPkg) {
        long el = SystemClock.elapsedRealtime();
        // our own block screen is already in front: pressing Back now would close it
        String cur = currentPackage();
        if (getPackageName().equals(cur)) return;
        if (!force && el - lastBlockEl < 1200) return;
        if (el - lastBlockEl < 400) return;
        lastBlockEl = el;
        if (reason == BlockActivity.R_SITE) {   // leave the blocked page, or reopening the browser re-blocks forever
            performGlobalAction(GLOBAL_ACTION_BACK);
        }
        showBlockScreen(reason);
        if (blockedPkg != null) {
            // Some ROMs silently refuse background activity starts: if the app is still in front, go Home.
            handler.postDelayed(() -> {
                try {
                    if (blockedPkg.equals(currentPackage())) {
                        performGlobalAction(GLOBAL_ACTION_HOME);
                        handler.postDelayed(() -> showBlockScreen(reason), 300);
                    }
                } catch (RuntimeException ignored) { }
            }, 600);
        }
    }

    private void showBlockScreen(int reason) {
        Intent i = new Intent(this, BlockActivity.class)
                .putExtra(BlockActivity.EXTRA_REASON, reason)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP
                        | Intent.FLAG_ACTIVITY_NO_ANIMATION | Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS);
        try { startActivity(i); } catch (RuntimeException ignored) { }
    }
}

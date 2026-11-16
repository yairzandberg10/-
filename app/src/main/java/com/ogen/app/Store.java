package com.ogen.app;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;

/**
 * Persists the {@link Policy} and provides a "trusted" clock.
 *
 * While a commitment is active, manual clock changes are absorbed into an offset
 * (detected by comparing the wall clock against elapsedRealtime), so moving the
 * clock forward does not end a lock early and moving it to tomorrow does not reset
 * today's usage.
 */
public final class Store {
    private static final String PREFS = "ogen";
    private static final long DRIFT = 90_000L;

    private static Policy cached;

    private Store() {}

    private static SharedPreferences sp(Context c) {
        return c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public static synchronized Policy policy(Context c) {
        if (cached == null) cached = Policy.parse(sp(c).getString("policy", null));
        return cached;
    }

    public static synchronized void save(Context c) {
        if (cached == null) return;
        sp(c).edit().putString("policy", cached.serialize()).apply();
    }

    /** Wall clock corrected for manual time changes made while committed. */
    public static synchronized long now(Context c) {
        SharedPreferences s = sp(c);
        long wall = System.currentTimeMillis();
        long el = SystemClock.elapsedRealtime();
        long offset = s.getLong("offset", 0);
        long lastWall = s.getLong("lastWall", 0);
        long lastEl = s.getLong("lastEl", -1);

        long lastTrusted = lastWall - offset;
        Policy p = policy(c);
        if (lastEl >= 0 && el >= lastEl) {
            // same boot: we know exactly how much real time passed
            long expected = lastWall + (el - lastEl);
            long jump = wall - expected;
            if (Math.abs(jump) > DRIFT && p.committed(lastTrusted)) offset += jump;
        } else if (lastEl >= 0) {
            // after a reboot: never let trusted time go backwards
            if (wall - offset < lastTrusted) offset = wall - lastTrusted;
        }
        long trusted = wall - offset;
        if (!p.committed(trusted) && offset != 0) {
            // nothing to protect: return to real time
            offset = 0;
            trusted = wall;
        }
        s.edit().putLong("offset", offset).putLong("lastWall", wall).putLong("lastEl", el).apply();
        return trusted;
    }

    public static long offset(Context c) {
        return sp(c).getLong("offset", 0);
    }

    /** Convert a trusted time into the device's wall clock, for display. */
    public static long toWall(Context c, long trusted) {
        return trusted + offset(c);
    }

    public static boolean flag(Context c, String key) {
        return sp(c).getBoolean(key, false);
    }

    public static void setFlag(Context c, String key, boolean v) {
        sp(c).edit().putBoolean(key, v).apply();
    }
}

package com.ogen.app;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * The whole commitment model, with no Android dependencies so it can be unit tested.
 *
 * Rule of the app: anything that makes you STRICTER happens immediately.
 * Anything that LOOSENS a commitment (larger limit, removing the limit, allowing
 * another app, turning off the social block) is queued and only takes effect
 * 24 hours later. There is no other way out.
 *
 * All times are "trusted" milliseconds (wall clock corrected for manual clock changes).
 */
public final class Policy {

    public static final long DAY = 24L * 60 * 60 * 1000;
    public static final long NONE = -1;

    public static final int CH_LIMIT = 1;       // value = new limit ms, or NONE to remove
    public static final int CH_ALLOW = 2;       // pkg = app to allow during lockdown
    public static final int CH_SOCIAL_OFF = 3;  // turn off the always-on social/video block

    public static final class Change {
        public final int type;
        public final long value;
        public final String pkg;
        public final long at;

        public Change(int type, long value, String pkg, long at) {
            this.type = type;
            this.value = value;
            this.pkg = pkg == null ? "" : pkg;
            this.at = at;
        }
    }

    // ---- persisted state ----
    public long limitMs = NONE;          // daily screen-time allowance
    public long usedMs = 0;              // used today
    public long usageDay = 0;            // start of the day usedMs belongs to
    public long hardUntil = 0;           // "lock now" end time
    public boolean socialBlock = true;   // always block social/video while committed
    public final Set<String> extraAllowed = new HashSet<>();
    public final List<Change> pending = new ArrayList<>();

    // ---- queries ----

    public boolean committed(long now) {
        return limitMs != NONE || hardUntil > now;
    }

    public boolean budgetSpent() {
        return limitMs != NONE && usedMs >= limitMs;
    }

    public boolean locked(long now) {
        return hardUntil > now || budgetSpent();
    }

    /** When the current lockdown ends (0 if not locked). */
    public long lockEnds(long now) {
        long end = 0;
        if (hardUntil > now) end = hardUntil;
        if (budgetSpent()) end = Math.max(end, nextDayStart(now));
        return end;
    }

    public long remainingMs() {
        if (limitMs == NONE) return NONE;
        return Math.max(0, limitMs - usedMs);
    }

    /** The limit value of a queued limit change, or null if none queued. */
    public Change pendingLimit() {
        for (Change c : pending) if (c.type == CH_LIMIT) return c;
        return null;
    }

    public Change pendingSocialOff() {
        for (Change c : pending) if (c.type == CH_SOCIAL_OFF) return c;
        return null;
    }

    public Change pendingAllow(String pkg) {
        for (Change c : pending) if (c.type == CH_ALLOW && c.pkg.equals(pkg)) return c;
        return null;
    }

    // ---- time housekeeping ----

    /** Resets daily usage at midnight and applies queued changes whose time has come. */
    public boolean tick(long now) {
        boolean changed = false;
        long today = dayStart(now);
        if (today > usageDay) {           // only ever moves forward
            usageDay = today;
            usedMs = 0;
            changed = true;
        }
        for (int i = pending.size() - 1; i >= 0; i--) {
            Change c = pending.get(i);
            if (c.at <= now) {
                apply(c);
                pending.remove(i);
                changed = true;
            }
        }
        if (hardUntil != 0 && hardUntil <= now) {
            hardUntil = 0;
            changed = true;
        }
        return changed;
    }

    public void addUsage(long ms, long now) {
        tick(now);
        if (ms > 0 && limitMs != NONE) usedMs += ms;
    }

    // ---- user requests ----

    /** @return true if applied immediately, false if queued for 24h. */
    public boolean requestLimit(long newLimit, long now) {
        tick(now);
        boolean stricter = newLimit != NONE && (limitMs == NONE || newLimit <= limitMs);
        if (stricter || !committed(now)) {
            removePending(CH_LIMIT, null);   // tightening cancels a queued loosening
            limitMs = newLimit;
            if (usageDay == 0) usageDay = dayStart(now);
            return true;
        }
        removePending(CH_LIMIT, null);
        pending.add(new Change(CH_LIMIT, newLimit, null, now + DAY));
        return false;
    }

    /** Lock everything except the allow-list until {@code until}. Can only be extended. */
    public void lockUntil(long until, long now) {
        tick(now);
        if (until > hardUntil) hardUntil = until;
    }

    public boolean requestAllow(String pkg, long now) {
        tick(now);
        if (extraAllowed.contains(pkg) || pendingAllow(pkg) != null) return false;
        if (!committed(now)) {
            extraAllowed.add(pkg);
            return true;
        }
        pending.add(new Change(CH_ALLOW, 0, pkg, now + DAY));
        return false;
    }

    /** Removing an app from the allow-list is stricter: immediate. */
    public void disallow(String pkg) {
        extraAllowed.remove(pkg);
        removePending(CH_ALLOW, pkg);
    }

    public boolean requestSocialBlock(boolean on, long now) {
        tick(now);
        if (on) {
            socialBlock = true;
            removePending(CH_SOCIAL_OFF, null);
            return true;
        }
        if (!socialBlock || pendingSocialOff() != null) return false;
        if (!committed(now)) {
            socialBlock = false;
            return true;
        }
        pending.add(new Change(CH_SOCIAL_OFF, 0, null, now + DAY));
        return false;
    }

    /** Withdrawing a queued loosening is always allowed (it is stricter). */
    public void cancelPending(int type, String pkg) {
        removePending(type, pkg);
    }

    // ---- internals ----

    private void apply(Change c) {
        switch (c.type) {
            case CH_LIMIT: limitMs = c.value; break;
            case CH_ALLOW: extraAllowed.add(c.pkg); break;
            case CH_SOCIAL_OFF: socialBlock = false; break;
            default: break;
        }
    }

    private void removePending(int type, String pkg) {
        for (int i = pending.size() - 1; i >= 0; i--) {
            Change c = pending.get(i);
            if (c.type == type && (pkg == null || c.pkg.equals(pkg))) pending.remove(i);
        }
    }

    public static long dayStart(long t) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(t);
        c.set(Calendar.HOUR_OF_DAY, 0);
        c.set(Calendar.MINUTE, 0);
        c.set(Calendar.SECOND, 0);
        c.set(Calendar.MILLISECOND, 0);
        return c.getTimeInMillis();
    }

    public static long nextDayStart(long t) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(dayStart(t));
        c.add(Calendar.DAY_OF_MONTH, 1);
        return c.getTimeInMillis();
    }

    // ---- serialization (plain text, one field per line) ----

    public String serialize() {
        StringBuilder b = new StringBuilder();
        b.append("v1\n");
        b.append(limitMs).append('\n').append(usedMs).append('\n').append(usageDay).append('\n')
                .append(hardUntil).append('\n').append(socialBlock ? 1 : 0).append('\n');
        boolean first = true;
        for (String a : extraAllowed) {
            if (!first) b.append(',');
            b.append(a);
            first = false;
        }
        b.append('\n');
        for (Change c : pending) {
            b.append(c.type).append('|').append(c.value).append('|').append(c.pkg).append('|').append(c.at).append('\n');
        }
        return b.toString();
    }

    public static Policy parse(String s) {
        Policy p = new Policy();
        if (s == null) return p;
        String[] l = s.split("\n", -1);
        if (l.length < 7 || !"v1".equals(l[0])) return p;
        try {
            p.limitMs = Long.parseLong(l[1]);
            p.usedMs = Long.parseLong(l[2]);
            p.usageDay = Long.parseLong(l[3]);
            p.hardUntil = Long.parseLong(l[4]);
            p.socialBlock = "1".equals(l[5]);
            for (String a : l[6].split(",")) if (!a.isEmpty()) p.extraAllowed.add(a);
            for (int i = 7; i < l.length; i++) {
                if (l[i].isEmpty()) continue;
                String[] f = l[i].split("\\|", -1);
                p.pending.add(new Change(Integer.parseInt(f[0]), Long.parseLong(f[1]), f[2], Long.parseLong(f[3])));
            }
        } catch (RuntimeException e) {
            // corrupted state: fail strict rather than open — keep what parsed
        }
        return p;
    }
}

package com.ogen.app;

import static org.junit.Assert.*;

import java.util.Calendar;
import org.junit.Test;

public class PolicyTest {
    static final long MIN = 60_000L, H = 60 * MIN;

    static long at(int day, int hour, int min) {
        Calendar c = Calendar.getInstance();
        c.set(2026, Calendar.NOVEMBER, day, hour, min, 0);
        c.set(Calendar.MILLISECOND, 0);
        return c.getTimeInMillis();
    }

    @Test public void tighteningIsImmediate_looseningIsQueued24h() {
        Policy p = new Policy();
        long t = at(16, 10, 0);
        assertTrue(p.requestLimit(60 * MIN, t));
        assertEquals(60 * MIN, p.limitMs);
        assertTrue(p.requestLimit(30 * MIN, t));
        assertEquals(30 * MIN, p.limitMs);
        assertFalse(p.requestLimit(120 * MIN, t));
        assertEquals(30 * MIN, p.limitMs);
        p.tick(t + 23 * H);
        assertEquals(30 * MIN, p.limitMs);
        p.tick(t + 24 * H);
        assertEquals(120 * MIN, p.limitMs);
    }

    @Test public void removingLimitIsQueued_andMidnightDoesNotHelp() {
        Policy p = new Policy();
        long t = at(16, 23, 55);
        p.requestLimit(10 * MIN, t);
        assertFalse(p.requestLimit(Policy.NONE, t));
        p.tick(at(17, 0, 1));
        assertEquals(10 * MIN, p.limitMs);
        assertTrue(p.committed(at(17, 0, 1)));
        p.tick(at(17, 23, 56));
        assertEquals(Policy.NONE, p.limitMs);
    }

    @Test public void budgetLocksUntilMidnight_thenResets() {
        Policy p = new Policy();
        long t = at(16, 9, 0);
        p.requestLimit(30 * MIN, t);
        p.addUsage(29 * MIN, t);
        assertFalse(p.locked(t));
        p.addUsage(2 * MIN, t);
        assertTrue(p.locked(t));
        assertEquals(at(17, 0, 0), p.lockEnds(t));
        p.tick(at(17, 0, 0));
        assertFalse(p.locked(at(17, 0, 0)));
        assertEquals(0, p.usedMs);
    }

    @Test public void hardLockOnlyExtends() {
        Policy p = new Policy();
        long t = at(16, 12, 0);
        p.lockUntil(t + 2 * H, t);
        p.lockUntil(t + H, t);
        assertEquals(t + 2 * H, p.hardUntil);
        assertTrue(p.locked(t + H));
        assertFalse(p.locked(t + 2 * H));
    }

    @Test public void tighteningCancelsQueuedLoosening() {
        Policy p = new Policy();
        long t = at(16, 10, 0);
        p.requestLimit(60 * MIN, t);
        p.requestLimit(240 * MIN, t);
        assertNotNull(p.pendingLimit());
        p.requestLimit(45 * MIN, t);
        assertNull(p.pendingLimit());
        assertEquals(45 * MIN, p.limitMs);
    }

    @Test public void allowAndSocialAreQueuedWhileCommitted() {
        Policy p = new Policy();
        long t = at(16, 10, 0);
        assertTrue(p.requestAllow("com.whatsapp", t)); // not committed yet: immediate
        p.requestLimit(60 * MIN, t);
        assertFalse(p.requestAllow("com.waze", t));
        assertFalse(p.extraAllowed.contains("com.waze"));
        assertFalse(p.requestSocialBlock(false, t));
        assertTrue(p.socialBlock);
        p.disallow("com.whatsapp");
        assertFalse(p.extraAllowed.contains("com.whatsapp"));
        p.tick(t + 24 * H);
        assertTrue(p.extraAllowed.contains("com.waze"));
        assertFalse(p.socialBlock);
    }

    @Test public void socialBlockIsOnByDefault_andTurningOffAlwaysWaits24h() {
        Policy p = new Policy();
        long t = at(16, 10, 0);
        assertTrue(p.socialBlock);
        assertTrue(p.guarding(t));
        assertFalse(p.committed(t));            // setup stays free: allow-list edits are immediate
        assertTrue(p.requestAllow("com.whatsapp", t));
        assertFalse(p.requestSocialBlock(false, t));
        assertTrue(p.socialBlock);
        p.tick(t + 24 * H - 1);
        assertTrue(p.socialBlock);
        p.tick(t + 24 * H);
        assertFalse(p.socialBlock);
        assertFalse(p.guarding(t + 24 * H));
    }

    @Test public void serializationRoundTrip() {
        Policy p = new Policy();
        long t = at(16, 10, 0);
        p.requestLimit(60 * MIN, t);
        p.addUsage(5 * MIN, t);
        p.lockUntil(t + H, t);
        p.requestAllow("com.waze", t);
        p.requestLimit(Policy.NONE, t);
        Policy q = Policy.parse(p.serialize());
        assertEquals(p.serialize(), q.serialize());
        assertEquals(2, q.pending.size());
    }
}

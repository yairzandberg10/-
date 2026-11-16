package com.ogen.app;

import android.app.AlertDialog;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Home fits one screen (built for ~320x455dp, e.g. Qin F22 Pro). Each setting is its own page.
 */
public class MainActivity extends BaseActivity {
    private static final long MIN = 60_000L;
    private static final long STEP = 15 * MIN;
    private static final int PICK_APP = 7;

    static final String EXTRA_PAGE = "page";
    static final int HOME = 0, LIMIT = 1, LOCK = 2, ALLOW = 3, SOCIAL = 4;

    // stable ids so keypad focus survives a re-render
    private static final int ID_ROW_LIMIT = 201, ID_ROW_LOCK = 202, ID_ROW_ALLOW = 203, ID_ROW_SOCIAL = 204,
            ID_SETUP = 205, ID_BACK = 206, ID_MINUS = 207, ID_PLUS = 208, ID_SAVE = 209, ID_REMOVE = 210,
            ID_CANCEL = 211, ID_TOGGLE = 212, ID_ADD = 213, ID_BATTERY = 214;

    private final Handler handler = new Handler();
    private int page = HOME;
    private long draft = -1;
    private ScrollView scroll;

    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            render();
            handler.postDelayed(this, 30_000);
        }
    };

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(Ui.color(this, R.color.paper));
        setContentView(scroll);
        page = getIntent().getIntExtra(EXTRA_PAGE, HOME);
    }

    @Override protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        setIntent(i);
        if (i.hasExtra(EXTRA_PAGE)) go(i.getIntExtra(EXTRA_PAGE, HOME));
    }

    @Override protected void onResume() {
        super.onResume();
        handler.post(refresh);
    }

    @Override protected void onPause() {
        handler.removeCallbacks(refresh);
        super.onPause();
    }

    @Override public void onBackPressed() {
        if (page != HOME) go(HOME);
        else super.onBackPressed();
    }

    private void go(int p) {
        int from = page;
        page = p;
        draft = -1;
        scroll.scrollTo(0, 0);
        render();
        // land keypad focus somewhere sensible
        int target = p == HOME ? rowIdFor(from) : ID_BACK;
        scroll.post(() -> {
            View v = scroll.findViewById(target);
            if (v != null) v.requestFocus();
        });
    }

    private static int rowIdFor(int page) {
        switch (page) {
            case LIMIT: return ID_ROW_LIMIT;
            case LOCK: return ID_ROW_LOCK;
            case ALLOW: return ID_ROW_ALLOW;
            case SOCIAL: return ID_ROW_SOCIAL;
            default: return ID_ROW_LIMIT;
        }
    }

    // ================================================================== render

    private void render() {
        View focused = getCurrentFocus();
        int focusId = focused == null ? View.NO_ID : focused.getId();
        int scrollY = scroll.getScrollY();

        Policy p = Store.policy(this);
        long now = Store.now(this);
        if (p.tick(now)) Store.save(this);

        LinearLayout root = Ui.col(this);
        switch (page) {
            case LIMIT: pageLimit(root, p, now); break;
            case LOCK: pageLock(root, p, now); break;
            case ALLOW: pageAllow(root, p, now); break;
            case SOCIAL: pageSocial(root, p, now); break;
            default: pageHome(root, p, now); break;
        }

        scroll.removeAllViews();
        scroll.addView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        scroll.post(() -> {
            scroll.scrollTo(0, scrollY);
            View f = focusId == View.NO_ID ? null : root.findViewById(focusId);
            if (f != null) f.requestFocus();
        });
    }

    // ------------------------------------------------------------------ home

    private void pageHome(LinearLayout root, Policy p, long now) {
        root.addView(topBar(p, now), Ui.match());

        View hero = GuardService.isRunning() ? hero(p, now) : setupHero();
        LinearLayout.LayoutParams hl = Ui.match();
        hl.setMargins(Ui.dp(this, 12), Ui.dp(this, 4), Ui.dp(this, 12), 0);
        root.addView(hero, hl);

        LinearLayout menu = Ui.col(this);
        menu.setPadding(Ui.dp(this, 4), Ui.dp(this, 10), Ui.dp(this, 4), Ui.dp(this, 8));

        String limitVal = p.limitMs == Policy.NONE ? "לא נקבעה" : Ui.hm(p.limitMs);
        if (p.pendingLimit() != null) limitVal += " ·  שינוי ממתין";
        menu.addView(menuRow(ID_ROW_LIMIT, "מגבלה יומית", limitVal, v -> go(LIMIT)));
        menu.addView(Ui.hairline(this));
        String lockVal = p.hardUntil > now ? "עד " + Ui.clock(Store.toWall(this, p.hardUntil)) : "";
        menu.addView(menuRow(ID_ROW_LOCK, "נעילה עכשיו", lockVal, v -> go(LOCK)));
        menu.addView(Ui.hairline(this));
        menu.addView(menuRow(ID_ROW_SOCIAL, "רשתות ויוטיוב", p.socialBlock ? "חסומים" : "פתוחים", v -> go(SOCIAL)));
        menu.addView(Ui.hairline(this));
        int n = 4 + p.extraAllowed.size();
        menu.addView(menuRow(ID_ROW_ALLOW, "מותר בנעילה", n + " אפליקציות", v -> go(ALLOW)));
        if (GuardService.isRunning() && !adminActive()) {
            menu.addView(Ui.hairline(this));
            menu.addView(alertRow(ID_BATTERY + 1, "הגנה מהסרת עוגן", "להפעיל", v ->
                    safeStart(new Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                            .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, new ComponentName(this, AdminReceiver.class))
                            .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION, getString(R.string.admin_desc)))));
        }
        if (GuardService.isRunning() && !ignoringBattery()) {
            menu.addView(Ui.hairline(this));
            menu.addView(alertRow(ID_BATTERY, "לא לעצור ברקע", "להפעיל", v ->
                    safeStart(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:" + getPackageName())))));
        }
        root.addView(menu, Ui.match());
    }

    private View topBar(Policy p, long now) {
        LinearLayout r = Ui.row(this);
        r.setPadding(Ui.dp(this, 16), Ui.dp(this, 10), Ui.dp(this, 16), Ui.dp(this, 6));
        ImageView mark = new ImageView(this);
        mark.setImageResource(R.drawable.ic_anchor);
        r.addView(mark, new LinearLayout.LayoutParams(Ui.dp(this, 18), Ui.dp(this, 18)));
        TextView name = Ui.text(this, "עוגן", 16, R.color.ink, Ui.MEDIUM);
        LinearLayout.LayoutParams lp = Ui.weight(this, 1, 0);
        lp.setMarginStart(Ui.dp(this, 6));
        r.addView(name, lp);

        boolean on = GuardService.isRunning();
        View dot = new View(this);
        dot.setBackgroundResource(on ? R.drawable.dot_ok : R.drawable.dot_bad);
        r.addView(dot, new LinearLayout.LayoutParams(Ui.dp(this, 7), Ui.dp(this, 7)));
        TextView st = Ui.text(this, on ? "מגן" : "כבוי", 12, on ? R.color.pine : R.color.brick, Ui.MEDIUM);
        LinearLayout.LayoutParams sl = Ui.wrap();
        sl.setMarginStart(Ui.dp(this, 5));
        r.addView(st, sl);
        return r;
    }

    private View hero(Policy p, long now) {
        long nowWall = System.currentTimeMillis();
        if (p.locked(now)) {
            LinearLayout c = Ui.col(this);
            c.setBackgroundResource(R.drawable.bg_hero_night);
            c.setGravity(Gravity.CENTER_HORIZONTAL);
            c.setPadding(Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16));
            long end = p.lockEnds(now);
            c.addView(center(Ui.text(this, p.hardUntil > now ? "נעול" : "הזמן להיום נגמר", 13, R.color.on_night_muted, Ui.MEDIUM)));
            TextView big = center(Ui.text(this, Ui.hm(end - now), 58, R.color.on_night, Ui.LIGHT));
            big.setIncludeFontPadding(false);
            c.addView(big, Ui.top(this, 4));
            c.addView(center(Ui.text(this, "נפתח " + Ui.when(Store.toWall(this, end), nowWall), 13, R.color.on_night_muted, Ui.REGULAR)), Ui.top(this, 6));
            return c;
        }
        LinearLayout c = Ui.col(this);
        c.setGravity(Gravity.CENTER_HORIZONTAL);
        c.setPadding(Ui.dp(this, 8), Ui.dp(this, 14), Ui.dp(this, 8), Ui.dp(this, 6));
        if (p.limitMs != Policy.NONE) {
            long left = p.remainingMs();
            boolean low = left < 10 * MIN;
            c.addView(center(Ui.text(this, "נשאר לך היום", 13, R.color.muted, Ui.MEDIUM)));
            TextView big = center(Ui.text(this, Ui.hm(left), 64, low ? R.color.brick : R.color.ink, Ui.LIGHT));
            big.setIncludeFontPadding(false);
            c.addView(big, Ui.top(this, 2));
            Ui.Bar bar = new Ui.Bar(this, Ui.color(this, R.color.line), Ui.color(this, low ? R.color.brick : R.color.pine));
            bar.set(p.limitMs == 0 ? 1 : (float) p.usedMs / p.limitMs);
            LinearLayout.LayoutParams bl = Ui.top(this, 12);
            bl.setMargins(Ui.dp(this, 24), Ui.dp(this, 12), Ui.dp(this, 24), 0);
            c.addView(bar, bl);
            c.addView(center(Ui.text(this, "מתוך " + Ui.hm(p.limitMs) + " · מתאפס בחצות", 12, R.color.muted, Ui.REGULAR)), Ui.top(this, 8));
        } else {
            c.addView(center(Ui.text(this, "אין מגבלה יומית", 13, R.color.muted, Ui.MEDIUM)));
            TextView big = center(Ui.text(this, "∞", 64, R.color.line, Ui.LIGHT));
            big.setIncludeFontPadding(false);
            c.addView(big, Ui.top(this, 0));
            c.addView(center(Ui.text(this, p.socialBlock ? "רשתות ויוטיוב חסומים כבר עכשיו" : "הטלפון פתוח לגמרי", 12, R.color.muted, Ui.REGULAR)), Ui.top(this, 4));
        }
        return c;
    }

    private View setupHero() {
        LinearLayout c = Ui.col(this);
        c.setBackgroundResource(R.drawable.bg_note);
        c.setPadding(Ui.dp(this, 14), Ui.dp(this, 12), Ui.dp(this, 14), Ui.dp(this, 14));
        c.addView(Ui.text(this, "עוגן עדיין לא שומר עליך", 16, R.color.brick, Ui.MEDIUM));
        c.addView(Ui.text(this, "צריך להפעיל אותו בהגדרות הנגישות. בלי זה שום דבר לא נחסם.", 13, R.color.ink2, Ui.REGULAR), Ui.top(this, 4));
        Button b = Ui.primary(this, "הפעלה בהגדרות נגישות");
        b.setId(ID_SETUP);
        b.setOnClickListener(v -> {
            Toast.makeText(this, "בחר \"עוגן\" והפעל", Toast.LENGTH_LONG).show();
            safeStart(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
        });
        c.addView(b, Ui.top(this, 10));
        return c;
    }

    private View menuRow(int id, String title, String value, View.OnClickListener l) {
        LinearLayout r = Ui.row(this);
        r.setId(id);
        r.setBackgroundResource(R.drawable.row_bg);
        r.setFocusable(true);
        r.setClickable(true);
        r.setMinimumHeight(Ui.dp(this, 50));
        r.setPadding(Ui.dp(this, 12), 0, Ui.dp(this, 10), 0);
        r.setOnClickListener(l);
        r.addView(Ui.text(this, title, 15, R.color.ink, Ui.REGULAR), Ui.weight(this, 1, 8));
        TextView v = Ui.text(this, value, 13, R.color.muted, Ui.REGULAR);
        v.setSingleLine(true);
        r.addView(v, Ui.wrap());
        TextView chev = Ui.text(this, "‹", 20, R.color.muted, Ui.LIGHT);
        LinearLayout.LayoutParams cl = Ui.wrap();
        cl.setMarginStart(Ui.dp(this, 8));
        r.addView(chev, cl);
        return r;
    }

    private View alertRow(int id, String title, String value, View.OnClickListener l) {
        View r = menuRow(id, title, value, l);
        TextView v = (TextView) ((LinearLayout) r).getChildAt(1);
        v.setTextColor(Ui.color(this, R.color.brick));
        v.setTypeface(Ui.MEDIUM);
        return r;
    }

    private static TextView center(TextView t) {
        t.setGravity(Gravity.CENTER);
        t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
        return t;
    }

    // ------------------------------------------------------------------ sub-page chrome

    private LinearLayout subPage(LinearLayout root, String title) {
        LinearLayout bar = Ui.row(this);
        bar.setPadding(Ui.dp(this, 4), Ui.dp(this, 4), Ui.dp(this, 12), 0);
        Button back = Ui.button(this, "→", R.drawable.row_bg, R.color.ink);
        back.setId(ID_BACK);
        back.setTextSize(20);
        back.setContentDescription("חזרה");
        back.setOnClickListener(v -> go(HOME));
        bar.addView(back, new LinearLayout.LayoutParams(Ui.dp(this, 48), Ui.dp(this, 48)));
        TextView t = Ui.text(this, title, 18, R.color.ink, Ui.MEDIUM);
        LinearLayout.LayoutParams tl = Ui.weight(this, 1, 0);
        tl.setMarginStart(Ui.dp(this, 4));
        bar.addView(t, tl);
        root.addView(bar, Ui.match());

        LinearLayout body = Ui.col(this);
        body.setPadding(Ui.dp(this, 16), Ui.dp(this, 4), Ui.dp(this, 16), Ui.dp(this, 20));
        root.addView(body, Ui.match());
        return body;
    }

    private TextView note(String s) {
        return Ui.text(this, s, 12, R.color.muted, Ui.REGULAR);
    }

    // ------------------------------------------------------------------ limit

    private void pageLimit(LinearLayout root, Policy p, long now) {
        LinearLayout b = subPage(root, "מגבלה יומית");
        if (draft < 0) draft = p.limitMs == Policy.NONE ? 60 * MIN : p.limitMs;

        LinearLayout stepper = Ui.row(this);
        Button minus = Ui.ghost(this, "−");
        minus.setId(ID_MINUS);
        minus.setTextSize(22);
        minus.setOnClickListener(v -> { draft = Math.max(STEP, draft - STEP); render(); });
        Button plus = Ui.ghost(this, "+");
        plus.setId(ID_PLUS);
        plus.setTextSize(22);
        plus.setOnClickListener(v -> { draft = Math.min(12 * 60 * MIN, draft + STEP); render(); });
        LinearLayout mid = Ui.col(this);
        mid.setGravity(Gravity.CENTER_HORIZONTAL);
        TextView val = center(Ui.text(this, Ui.hm(draft), 44, R.color.ink, Ui.LIGHT));
        val.setIncludeFontPadding(false);
        mid.addView(val, Ui.wrap());
        mid.addView(center(Ui.text(this, Ui.words(draft) + " ביום", 12, R.color.muted, Ui.REGULAR)), Ui.top(this, 2));
        LinearLayout.LayoutParams sq = new LinearLayout.LayoutParams(Ui.dp(this, 52), Ui.dp(this, 52));
        stepper.addView(plus, sq);
        stepper.addView(mid, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        stepper.addView(minus, new LinearLayout.LayoutParams(Ui.dp(this, 52), Ui.dp(this, 52)));
        b.addView(stepper, Ui.top(this, 10));

        boolean looser = p.limitMs != Policy.NONE && draft > p.limitMs && p.committed(now);
        boolean same = p.limitMs == draft;
        Button save = looser ? Ui.ghost(this, "בקש הגדלה · בעוד 24 שעות")
                : Ui.primary(this, p.limitMs == Policy.NONE ? "קבע מגבלה" : "עדכן מגבלה");
        save.setId(ID_SAVE);
        save.setEnabled(!same);
        save.setAlpha(same ? 0.4f : 1f);
        save.setOnClickListener(v -> confirmLimit(draft));
        b.addView(save, Ui.top(this, 16));

        Policy.Change pend = p.pendingLimit();
        if (pend != null) {
            String what = pend.value == Policy.NONE ? "הסרת המגבלה" : "מגבלה של " + Ui.hm(pend.value);
            b.addView(pendingNote(what + " תיכנס לתוקף " + whenTrusted(pend.at),
                    v -> { p.cancelPending(Policy.CH_LIMIT, null); Store.save(this); render(); }), Ui.top(this, 10));
        } else if (p.limitMs != Policy.NONE) {
            Button rm = Ui.button(this, "הסרת המגבלה", R.drawable.row_bg, R.color.muted);
            rm.setId(ID_REMOVE);
            rm.setTextSize(13);
            rm.setOnClickListener(v -> confirmLimit(Policy.NONE));
            b.addView(rm, Ui.top(this, 4));
        }
        b.addView(note("כשהזמן נגמר הטלפון ננעל עד חצות. הקטנה נכנסת מיד; הגדלה או הסרה – רק אחרי 24 שעות."), Ui.top(this, 12));
    }

    // ------------------------------------------------------------------ lock

    private void pageLock(LinearLayout root, Policy p, long now) {
        LinearLayout b = subPage(root, "נעילה עכשיו");
        if (p.hardUntil > now) {
            b.addView(Ui.text(this, "נעול עד " + whenTrusted(p.hardUntil) + ". אפשר רק להאריך.", 13, R.color.pine, Ui.MEDIUM), Ui.top(this, 2));
        }
        b.addView(note("רק שיחות, הודעות, מוביט והאפליקציות שאישרת. אין כפתור ביטול."), Ui.top(this, 2));

        LinearLayout list = Ui.col(this);
        int id = 400;
        list.addView(lockRow(id++, "5 דקות", "ניסיון – כדאי להתחיל כאן", 5 * MIN, "ל-5 דקות"));
        list.addView(Ui.hairline(this));
        list.addView(lockRow(id++, "שעה", null, 60 * MIN, "לשעה"));
        list.addView(Ui.hairline(this));
        list.addView(lockRow(id++, "3 שעות", null, 180 * MIN, "ל-3 שעות"));
        list.addView(Ui.hairline(this));
        list.addView(lockRow(id, "עד חצות", "עד " + Ui.clock(Store.toWall(this, Policy.nextDayStart(now))), -1, "עד חצות"));
        LinearLayout.LayoutParams ll = Ui.top(this, 10);
        ll.setMargins(-Ui.dp(this, 12), Ui.dp(this, 10), -Ui.dp(this, 12), 0);
        b.addView(list, ll);
    }

    private View lockRow(int id, String title, String sub, long dur, String label) {
        LinearLayout r = Ui.row(this);
        r.setId(id);
        r.setBackgroundResource(R.drawable.row_bg);
        r.setFocusable(true);
        r.setClickable(true);
        r.setMinimumHeight(Ui.dp(this, 50));
        r.setPadding(Ui.dp(this, 12), Ui.dp(this, 6), Ui.dp(this, 12), Ui.dp(this, 6));
        LinearLayout t = Ui.col(this);
        t.addView(Ui.text(this, title, 15, R.color.ink, Ui.REGULAR), Ui.wrap());
        if (sub != null) t.addView(Ui.text(this, sub, 12, R.color.muted, Ui.REGULAR), Ui.wrap());
        r.addView(t, Ui.weight(this, 1, 0));
        r.addView(Ui.text(this, "נעל", 13, R.color.pine, Ui.MEDIUM), Ui.wrap());
        r.setOnClickListener(v -> {
            long now = Store.now(this);
            confirmLock(dur < 0 ? Policy.nextDayStart(now) : now + dur, label);
        });
        return r;
    }

    // ------------------------------------------------------------------ social

    private void pageSocial(LinearLayout root, Policy p, long now) {
        LinearLayout b = subPage(root, "רשתות ויוטיוב");
        b.addView(Ui.text(this, p.socialBlock ? "חסומים – תמיד" : "פתוחים", 22, p.socialBlock ? R.color.pine : R.color.brick, Ui.MEDIUM), Ui.top(this, 2));
        b.addView(Ui.text(this, "אינסטגרם, טיקטוק, יוטיוב, פייסבוק, X, סנאפצ׳ט, רדיט, נטפליקס וטוויץ׳ – האפליקציות וגם האתרים בדפדפן. החסימה פועלת כל הזמן, גם בלי מגבלה יומית.", 13, R.color.ink2, Ui.REGULAR), Ui.top(this, 6));

        Policy.Change pend = p.pendingSocialOff();
        if (pend != null) {
            b.addView(pendingNote("תכובה " + whenTrusted(pend.at), v -> {
                p.cancelPending(Policy.CH_SOCIAL_OFF, null);
                Store.save(this);
                render();
            }), Ui.top(this, 14));
        } else if (p.socialBlock) {
            Button off = Ui.button(this, "לכבות (בעוד 24 שעות)", R.drawable.row_bg, R.color.muted);
            off.setId(ID_TOGGLE);
            off.setTextSize(13);
            off.setOnClickListener(v -> confirmSocialOff());
            b.addView(off, Ui.top(this, 14));
        } else {
            Button on = Ui.primary(this, "לחסום שוב – מיד");
            on.setId(ID_TOGGLE);
            on.setOnClickListener(v -> {
                Store.policy(this).requestSocialBlock(true, Store.now(this));
                Store.save(this);
                render();
            });
            b.addView(on, Ui.top(this, 14));
        }
    }

    // ------------------------------------------------------------------ allow-list

    private void pageAllow(LinearLayout root, Policy p, long now) {
        LinearLayout b = subPage(root, "מותר בנעילה");
        b.addView(Ui.text(this, "שיחות · הודעות · אנשי קשר · מוביט", 14, R.color.ink, Ui.REGULAR), Ui.top(this, 2));
        b.addView(note("תמיד מותרים, ואי אפשר להסיר אותם."), Ui.top(this, 2));

        PackageManager pm = getPackageManager();
        List<String> extra = new ArrayList<>(p.extraAllowed);
        Collections.sort(extra);
        int id = 300;
        for (String pkg : extra) {
            b.addView(appRow(appName(pm, pkg), null, "הסר", id++, v -> {
                p.disallow(pkg);
                Store.save(this);
                render();
            }), Ui.top(this, 8));
        }
        for (Policy.Change ch : new ArrayList<>(p.pending)) {
            if (ch.type != Policy.CH_ALLOW) continue;
            b.addView(appRow(appName(pm, ch.pkg), "תתווסף " + whenTrusted(ch.at), "בטל", id++, v -> {
                p.cancelPending(Policy.CH_ALLOW, ch.pkg);
                Store.save(this);
                render();
            }), Ui.top(this, 8));
        }
        Button add = Ui.ghost(this, "+ הוספת אפליקציה");
        add.setId(ID_ADD);
        add.setOnClickListener(v -> startActivityForResult(new Intent(this, AppPickerActivity.class), PICK_APP));
        b.addView(add, Ui.top(this, 14));
        b.addView(note(p.committed(now) ? "הוספה נכנסת לתוקף אחרי 24 שעות. הסרה – מיד." : "בלי מגבלה פעילה, הוספה נכנסת מיד."), Ui.top(this, 8));

    }

    // ------------------------------------------------------------------ pieces

    private View pendingNote(String text, View.OnClickListener cancel) {
        LinearLayout r = Ui.row(this);
        r.setBackgroundResource(R.drawable.bg_note);
        r.setPadding(Ui.dp(this, 12), Ui.dp(this, 6), Ui.dp(this, 6), Ui.dp(this, 6));
        r.addView(Ui.text(this, text, 12, R.color.brick, Ui.MEDIUM), Ui.weight(this, 1, 6));
        Button b = Ui.button(this, "בטל", R.drawable.btn_ghost, R.color.brick);
        b.setId(ID_CANCEL);
        b.setTextSize(12);
        b.setMinHeight(Ui.dp(this, 36));
        b.setMinimumHeight(Ui.dp(this, 36));
        b.setOnClickListener(cancel);
        r.addView(b, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, Ui.dp(this, 36)));
        return r;
    }

    private View appRow(String name, String noteText, String action, int id, View.OnClickListener l) {
        LinearLayout r = Ui.row(this);
        LinearLayout t = Ui.col(this);
        TextView n = Ui.text(this, name, 15, R.color.ink, Ui.REGULAR);
        n.setSingleLine(true);
        n.setEllipsize(TextUtils.TruncateAt.END);
        t.addView(n, Ui.wrap());
        if (noteText != null) t.addView(Ui.text(this, noteText, 12, R.color.brick, Ui.REGULAR), Ui.wrap());
        r.addView(t, Ui.weight(this, 1, 8));
        Button b = Ui.button(this, action, R.drawable.btn_ghost, R.color.ink2);
        b.setId(id);
        b.setTextSize(12);
        b.setMinHeight(Ui.dp(this, 36));
        b.setMinimumHeight(Ui.dp(this, 36));
        b.setOnClickListener(l);
        r.addView(b, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, Ui.dp(this, 36)));
        return r;
    }

    private String whenTrusted(long trusted) {
        return Ui.when(Store.toWall(this, trusted), System.currentTimeMillis());
    }

    private static String appName(PackageManager pm, String pkg) {
        try {
            ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            return pm.getApplicationLabel(ai).toString();
        } catch (PackageManager.NameNotFoundException e) {
            return pkg;
        }
    }

    // ================================================================== actions

    private void confirmLimit(long value) {
        Policy p = Store.policy(this);
        long now = Store.now(this);
        boolean committed = p.committed(now);
        boolean stricter = value != Policy.NONE && (p.limitMs == Policy.NONE || value <= p.limitMs);
        String title, msg;
        if (value == Policy.NONE) {
            title = "להסיר את המגבלה?";
            msg = "ההסרה תיכנס לתוקף רק בעוד 24 שעות. עד אז המגבלה הנוכחית ממשיכה.";
        } else if (stricter || !committed) {
            title = Ui.words(value) + " ביום";
            msg = "נכנס לתוקף מיד. אחרי האישור לא תוכל להגדיל או לבטל במשך 24 שעות.";
        } else {
            title = "להגדיל ל-" + Ui.words(value) + "?";
            msg = "ההגדלה תיכנס לתוקף רק בעוד 24 שעות. אפשר לבטל את הבקשה בכל רגע.";
        }
        if (!GuardService.isRunning()) msg += "\n\nעוגן כבוי בהגדרות הנגישות – שום דבר לא ייחסם עד שתפעיל אותו.";
        new AlertDialog.Builder(this)
                .setTitle(title)
                .setMessage(msg)
                .setPositiveButton("אישור", (d, w) -> {
                    boolean applied = Store.policy(this).requestLimit(value, Store.now(this));
                    Store.save(this);
                    Toast.makeText(this, applied ? "נקבע" : "נרשם – ייכנס לתוקף בעוד 24 שעות", Toast.LENGTH_SHORT).show();
                    go(HOME);
                })
                .setNegativeButton("ביטול", null)
                .show();
    }

    private void confirmLock(long until, String label) {
        String msg = "עד " + Ui.when(Store.toWall(this, until), System.currentTimeMillis())
                + " – רק שיחות, הודעות ומוביט. אין דרך לבטל.";
        if (!GuardService.isRunning()) msg += "\n\nעוגן כבוי בהגדרות הנגישות – הנעילה לא תיאכף.";
        new AlertDialog.Builder(this)
                .setTitle("לנעול " + label + "?")
                .setMessage(msg)
                .setPositiveButton("נעל", (d, w) -> {
                    Store.policy(this).lockUntil(until, Store.now(this));
                    Store.save(this);
                    go(HOME);
                })
                .setNegativeButton("ביטול", null)
                .show();
    }

    private void confirmSocialOff() {
        new AlertDialog.Builder(this)
                .setTitle("לכבות את החסימה?")
                .setMessage("הכיבוי ייכנס לתוקף רק בעוד 24 שעות. עד אז הכל נשאר חסום, ואפשר לבטל את הבקשה.")
                .setPositiveButton("אישור", (d, w) -> {
                    Store.policy(this).requestSocialBlock(false, Store.now(this));
                    Store.save(this);
                    render();
                })
                .setNegativeButton("ביטול", null)
                .show();
    }

    @Override protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != PICK_APP || res != RESULT_OK || data == null) return;
        String pkg = data.getStringExtra(AppPickerActivity.EXTRA_PKG);
        if (pkg == null) return;
        boolean immediate = Store.policy(this).requestAllow(pkg, Store.now(this));
        Store.save(this);
        Toast.makeText(this, immediate ? "נוספה" : "תתווסף בעוד 24 שעות", Toast.LENGTH_SHORT).show();
        page = ALLOW;
        render();
    }

    private boolean adminActive() {
        DevicePolicyManager dpm = (DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
        return dpm != null && dpm.isAdminActive(new ComponentName(this, AdminReceiver.class));
    }

    private boolean ignoringBattery() {
        if (Build.VERSION.SDK_INT < 23) return true;
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        return pm == null || pm.isIgnoringBatteryOptimizations(getPackageName());
    }

    private void safeStart(Intent i) {
        try {
            startActivity(i);
        } catch (RuntimeException e) {
            Toast.makeText(this, "לא הצלחתי לפתוח את ההגדרות", Toast.LENGTH_SHORT).show();
        }
    }
}

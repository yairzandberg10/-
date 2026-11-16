package com.ogen.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
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

public class MainActivity extends Activity {
    private static final long MIN = 60_000L;
    private static final long STEP = 15 * MIN;
    private static final int PICK_APP = 7;

    // stable ids so keypad focus survives a re-render
    private static final int ID_MINUS = 101, ID_PLUS = 102, ID_SET = 103, ID_REMOVE = 104,
            ID_L1 = 105, ID_L3 = 106, ID_LMID = 107, ID_SOCIAL = 108, ID_ADD = 109,
            ID_A11Y = 110, ID_TRIAL = 114, ID_ADMIN = 111, ID_CANCEL_LIMIT = 112, ID_CANCEL_SOCIAL = 113;

    private final Handler handler = new Handler();
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
    }

    @Override protected void onResume() {
        super.onResume();
        handler.post(refresh);
    }

    @Override protected void onPause() {
        handler.removeCallbacks(refresh);
        super.onPause();
    }

    // ------------------------------------------------------------------ render

    private void render() {
        View focused = getCurrentFocus();
        int focusId = focused == null ? View.NO_ID : focused.getId();
        int scrollY = scroll.getScrollY();

        Policy p = Store.policy(this);
        long now = Store.now(this);
        if (p.tick(now)) Store.save(this);
        if (draft < 0) draft = p.limitMs == Policy.NONE ? 60 * MIN : p.limitMs;

        LinearLayout root = Ui.col(this);
        int side = Ui.dp(this, 12);
        root.setPadding(side, Ui.dp(this, 12), side, Ui.dp(this, 24));

        root.addView(header(p, now), Ui.match());
        root.addView(hero(p, now), Ui.top(this, 12));
        View setup = setupCard();
        if (setup != null) root.addView(setup, Ui.top(this, 10));
        root.addView(limitCard(p, now), Ui.top(this, 10));
        root.addView(lockCard(p, now), Ui.top(this, 10));
        root.addView(allowCard(p, now), Ui.top(this, 10));
        root.addView(socialCard(p, now), Ui.top(this, 10));

        TextView rule = Ui.text(this, "הכלל של עוגן: כל החמרה נכנסת מיד. כל הקלה נכנסת רק אחרי 24 שעות, ואין דרך לעקוף את זה.", 12, R.color.muted, Ui.REGULAR);
        rule.setPadding(Ui.dp(this, 4), 0, Ui.dp(this, 4), 0);
        root.addView(rule, Ui.top(this, 16));

        scroll.removeAllViews();
        scroll.addView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        scroll.post(() -> {
            scroll.scrollTo(0, scrollY);
            View f = focusId == View.NO_ID ? null : root.findViewById(focusId);
            if (f != null) f.requestFocus();
        });
    }

    private View header(Policy p, long now) {
        LinearLayout r = Ui.row(this);
        ImageView mark = new ImageView(this);
        mark.setImageResource(R.drawable.ic_anchor);
        r.addView(mark, new LinearLayout.LayoutParams(Ui.dp(this, 22), Ui.dp(this, 22)));
        TextView name = Ui.text(this, "עוגן", 19, R.color.ink, Ui.MEDIUM);
        LinearLayout.LayoutParams lp = Ui.weight(this, 1, 0);
        lp.setMarginStart(Ui.dp(this, 8));
        r.addView(name, lp);

        boolean guarded = GuardService.isRunning();
        TextView chip = Ui.text(this, guarded ? (p.committed(now) ? "מגן" : "מוכן") : "לא פעיל", 12,
                guarded ? R.color.pine : R.color.brick, Ui.MEDIUM);
        chip.setBackgroundResource(guarded ? R.drawable.bg_chip : R.drawable.bg_note);
        chip.setPadding(Ui.dp(this, 10), Ui.dp(this, 3), Ui.dp(this, 10), Ui.dp(this, 3));
        r.addView(chip, Ui.wrap());
        return r;
    }

    private View hero(Policy p, long now) {
        long nowWall = System.currentTimeMillis();
        if (p.locked(now)) {
            LinearLayout c = Ui.col(this);
            c.setBackgroundResource(R.drawable.bg_hero_night);
            int pad = Ui.dp(this, 16);
            c.setPadding(pad, Ui.dp(this, 14), pad, pad);
            long end = p.lockEnds(now);
            c.addView(labelOn(p.hardUntil > now ? "נעילה פעילה" : "הזמן להיום נגמר", R.color.on_night_muted));
            TextView big = Ui.text(this, Ui.hm(end - now), 48, R.color.on_night, Ui.LIGHT);
            big.setIncludeFontPadding(false);
            c.addView(big, Ui.top(this, 6));
            c.addView(Ui.text(this, "נפתח " + Ui.when(Store.toWall(this, end), nowWall), 14, R.color.on_night_muted, Ui.REGULAR), Ui.top(this, 4));
            c.addView(Ui.text(this, "עד אז: שיחות, הודעות ומוביט בלבד.", 13, R.color.on_night_muted, Ui.REGULAR), Ui.top(this, 10));
            return c;
        }
        LinearLayout c = Ui.card(this);
        if (p.limitMs != Policy.NONE) {
            long left = p.remainingMs();
            c.addView(Ui.label(this, "זמן חופשי שנשאר היום"));
            TextView big = Ui.text(this, Ui.hm(left), 48, left < 10 * MIN ? R.color.brick : R.color.pine, Ui.LIGHT);
            big.setIncludeFontPadding(false);
            c.addView(big, Ui.top(this, 6));
            Ui.Bar bar = new Ui.Bar(this, Ui.color(this, R.color.line), Ui.color(this, left < 10 * MIN ? R.color.brick : R.color.pine));
            bar.set(p.limitMs == 0 ? 1 : (float) p.usedMs / p.limitMs);
            c.addView(bar, Ui.top(this, 12));
            c.addView(Ui.text(this, "נוצלו " + Ui.hm(p.usedMs) + " מתוך " + Ui.hm(p.limitMs) + " · מתאפס בחצות", 12, R.color.muted, Ui.REGULAR), Ui.top(this, 8));
        } else {
            c.addView(Ui.label(this, "אין מגבלה פעילה"));
            c.addView(Ui.text(this, "הטלפון פתוח לגמרי.", 22, R.color.ink, Ui.MEDIUM), Ui.top(this, 6));
            c.addView(Ui.text(this, "קבע זמן יומי או נעל עכשיו. מרגע שתאשר – לא תוכל להתחרט במשך 24 שעות.", 13, R.color.ink2, Ui.REGULAR), Ui.top(this, 6));
        }
        return c;
    }

    private TextView labelOn(String s, int colorRes) {
        TextView t = Ui.label(this, s);
        t.setTextColor(Ui.color(this, colorRes));
        return t;
    }

    private View setupCard() {
        boolean a11y = GuardService.isRunning();
        boolean admin = adminActive();
        if (a11y && admin) return null;
        LinearLayout c = Ui.card(this);
        c.addView(Ui.label(this, "השלמת הגדרה"));
        c.addView(Ui.text(this, a11y ? "כדי שלא תוכל פשוט למחוק את עוגן:" : "בלי שירות הנגישות עוגן לא יכול לחסום כלום.", 13, R.color.ink2, Ui.REGULAR), Ui.top(this, 4));
        if (!a11y) {
            Button b = Ui.primary(this, "הפעל שירות נגישות");
            b.setId(ID_A11Y);
            b.setOnClickListener(v -> {
                Toast.makeText(this, "בחר ב\"עוגן\" והפעל", Toast.LENGTH_LONG).show();
                safeStart(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
            });
            c.addView(b, Ui.top(this, 10));
        }
        if (!admin) {
            Button b = a11y ? Ui.primary(this, "הפעל הגנה מהסרה") : Ui.ghost(this, "הפעל הגנה מהסרה");
            b.setId(ID_ADMIN);
            b.setOnClickListener(v -> {
                Intent i = new Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                        .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, new ComponentName(this, AdminReceiver.class))
                        .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION, getString(R.string.admin_desc));
                safeStart(i);
            });
            c.addView(b, Ui.top(this, 8));
        }
        return c;
    }

    private View limitCard(Policy p, long now) {
        LinearLayout c = Ui.card(this);
        c.addView(Ui.label(this, "מגבלה יומית"));

        LinearLayout stepper = Ui.row(this);
        Button minus = Ui.ghost(this, "−");
        minus.setId(ID_MINUS);
        minus.setTextSize(20);
        minus.setOnClickListener(v -> { draft = Math.max(STEP, draft - STEP); render(); });
        Button plus = Ui.ghost(this, "+");
        plus.setId(ID_PLUS);
        plus.setTextSize(20);
        plus.setOnClickListener(v -> { draft = Math.min(12 * 60 * MIN, draft + STEP); render(); });
        LinearLayout mid = Ui.col(this);
        mid.setGravity(Gravity.CENTER_HORIZONTAL);
        TextView val = Ui.text(this, Ui.hm(draft), 30, R.color.ink, Ui.LIGHT);
        val.setGravity(Gravity.CENTER);
        mid.addView(val, Ui.wrap());
        TextView words = Ui.text(this, Ui.words(draft) + " ביום", 12, R.color.muted, Ui.REGULAR);
        words.setGravity(Gravity.CENTER);
        mid.addView(words, Ui.wrap());

        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(Ui.dp(this, 52), Ui.dp(this, 48));
        stepper.addView(minus, bp);
        stepper.addView(mid, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        stepper.addView(plus, new LinearLayout.LayoutParams(Ui.dp(this, 52), Ui.dp(this, 48)));
        c.addView(stepper, Ui.top(this, 8));

        boolean committed = p.committed(now);
        boolean looser = p.limitMs != Policy.NONE && draft > p.limitMs && committed;
        boolean same = p.limitMs == draft;
        Button set;
        if (looser) set = Ui.ghost(this, "בקש הגדלה · בעוד 24 שעות");
        else set = Ui.primary(this, p.limitMs == Policy.NONE ? "קבע מגבלה" : "עדכן מגבלה");
        set.setId(ID_SET);
        set.setEnabled(!same);
        set.setAlpha(same ? 0.45f : 1f);
        set.setOnClickListener(v -> confirmLimit(draft));
        c.addView(set, Ui.top(this, 10));

        Policy.Change pend = p.pendingLimit();
        if (pend != null) {
            String what = pend.value == Policy.NONE ? "הסרת המגבלה" : "מגבלה של " + Ui.hm(pend.value);
            c.addView(pendingNote(what + " תיכנס לתוקף " + whenTrusted(pend.at), ID_CANCEL_LIMIT,
                    v -> { p.cancelPending(Policy.CH_LIMIT, null); Store.save(this); render(); }), Ui.top(this, 10));
        } else if (p.limitMs != Policy.NONE) {
            Button rm = Ui.button(this, "הסר מגבלה", R.drawable.row_bg, R.color.muted);
            rm.setId(ID_REMOVE);
            rm.setTextSize(13);
            rm.setOnClickListener(v -> confirmLimit(Policy.NONE));
            c.addView(rm, Ui.top(this, 4));
        }
        return c;
    }

    private View lockCard(Policy p, long now) {
        LinearLayout c = Ui.card(this);
        c.addView(Ui.label(this, "נעילה מיידית"));
        c.addView(Ui.text(this, "הכל נסגר חוץ משיחות, הודעות ומוביט. אי אפשר לבטל.", 13, R.color.ink2, Ui.REGULAR), Ui.top(this, 4));
        LinearLayout r = Ui.row(this);
        Button h1 = Ui.ghost(this, "שעה");
        h1.setId(ID_L1);
        h1.setOnClickListener(v -> confirmLock(Store.now(this) + 60 * MIN, "לשעה"));
        Button h3 = Ui.ghost(this, "3 שעות");
        h3.setId(ID_L3);
        h3.setOnClickListener(v -> confirmLock(Store.now(this) + 180 * MIN, "ל-3 שעות"));
        Button mid = Ui.ghost(this, "עד חצות");
        mid.setId(ID_LMID);
        mid.setOnClickListener(v -> confirmLock(Policy.nextDayStart(Store.now(this)), "עד חצות"));
        r.addView(h1, Ui.weight(this, 1, 6));
        r.addView(h3, Ui.weight(this, 1, 6));
        r.addView(mid, Ui.weight(this, 1.2f, 0));
        c.addView(r, Ui.top(this, 10));
        Button trial = Ui.button(this, "נסה קודם: נעילה של 5 דקות", R.drawable.row_bg, R.color.pine);
        trial.setId(ID_TRIAL);
        trial.setTextSize(13);
        trial.setOnClickListener(v -> confirmLock(Store.now(this) + 5 * MIN, "ל-5 דקות"));
        c.addView(trial, Ui.top(this, 6));
        if (p.hardUntil > now) {
            c.addView(Ui.text(this, "נעול עד " + Ui.when(Store.toWall(this, p.hardUntil), System.currentTimeMillis()) + ". אפשר רק להאריך.", 12, R.color.muted, Ui.REGULAR), Ui.top(this, 8));
        }
        return c;
    }

    private View allowCard(Policy p, long now) {
        LinearLayout c = Ui.card(this);
        c.addView(Ui.label(this, "מותר גם בזמן נעילה"));
        c.addView(Ui.text(this, "שיחות · הודעות · אנשי קשר · מוביט", 14, R.color.ink, Ui.REGULAR), Ui.top(this, 4));

        PackageManager pm = getPackageManager();
        List<String> extra = new ArrayList<>(p.extraAllowed);
        Collections.sort(extra);
        int id = 300;
        for (String pkg : extra) {
            c.addView(appRow(appName(pm, pkg), null, "הסר", id++, v -> {
                p.disallow(pkg);
                Store.save(this);
                render();
            }), Ui.top(this, 6));
        }
        for (Policy.Change ch : new ArrayList<>(p.pending)) {
            if (ch.type != Policy.CH_ALLOW) continue;
            c.addView(appRow(appName(pm, ch.pkg), "יתווסף " + whenTrusted(ch.at), "בטל", id++, v -> {
                p.cancelPending(Policy.CH_ALLOW, ch.pkg);
                Store.save(this);
                render();
            }), Ui.top(this, 6));
        }
        Button add = Ui.ghost(this, "+ הוסף אפליקציה");
        add.setId(ID_ADD);
        add.setOnClickListener(v -> startActivityForResult(new Intent(this, AppPickerActivity.class), PICK_APP));
        c.addView(add, Ui.top(this, 10));
        if (p.committed(now)) {
            c.addView(Ui.text(this, "הוספה נכנסת לתוקף אחרי 24 שעות. הסרה – מיד.", 12, R.color.muted, Ui.REGULAR), Ui.top(this, 6));
        }
        return c;
    }

    private View socialCard(Policy p, long now) {
        LinearLayout c = Ui.card(this);
        LinearLayout r = Ui.row(this);
        LinearLayout t = Ui.col(this);
        t.addView(Ui.text(this, "רשתות ויוטיוב חסומים תמיד", 14, R.color.ink, Ui.MEDIUM), Ui.wrap());
        t.addView(Ui.text(this, "גם בזמן החופשי: אינסטגרם, טיקטוק, יוטיוב ואתריהם בדפדפן.", 12, R.color.muted, Ui.REGULAR), Ui.top(this, 2));
        r.addView(t, Ui.weight(this, 1, 8));
        Policy.Change pend = p.pendingSocialOff();
        Button b = p.socialBlock ? Ui.primary(this, "פועל") : Ui.ghost(this, "כבוי");
        b.setId(ID_SOCIAL);
        b.setOnClickListener(v -> {
            if (!p.socialBlock) {
                p.requestSocialBlock(true, Store.now(this));
                Store.save(this);
                render();
            } else if (pend == null) {
                confirmSocialOff();
            }
        });
        r.addView(b, new LinearLayout.LayoutParams(Ui.dp(this, 70), Ui.dp(this, 40)));
        c.addView(r, Ui.match());
        if (pend != null) {
            c.addView(pendingNote("יכובה " + whenTrusted(pend.at), ID_CANCEL_SOCIAL, v -> {
                p.cancelPending(Policy.CH_SOCIAL_OFF, null);
                Store.save(this);
                render();
            }), Ui.top(this, 10));
        }
        return c;
    }

    // ------------------------------------------------------------------ pieces

    private View pendingNote(String text, int id, View.OnClickListener cancel) {
        LinearLayout r = Ui.row(this);
        r.setBackgroundResource(R.drawable.bg_note);
        r.setPadding(Ui.dp(this, 10), Ui.dp(this, 6), Ui.dp(this, 6), Ui.dp(this, 6));
        TextView t = Ui.text(this, text, 12, R.color.brick, Ui.MEDIUM);
        r.addView(t, Ui.weight(this, 1, 6));
        Button b = Ui.button(this, "בטל", R.drawable.btn_ghost, R.color.brick);
        b.setId(id);
        b.setTextSize(12);
        b.setMinHeight(Ui.dp(this, 34));
        b.setMinimumHeight(Ui.dp(this, 34));
        b.setOnClickListener(cancel);
        r.addView(b, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, Ui.dp(this, 34)));
        return r;
    }

    private View appRow(String name, String note, String action, int id, View.OnClickListener l) {
        LinearLayout r = Ui.row(this);
        LinearLayout t = Ui.col(this);
        TextView n = Ui.text(this, name, 14, R.color.ink, Ui.REGULAR);
        n.setSingleLine(true);
        n.setEllipsize(TextUtils.TruncateAt.END);
        t.addView(n, Ui.wrap());
        if (note != null) t.addView(Ui.text(this, note, 12, R.color.brick, Ui.REGULAR), Ui.wrap());
        r.addView(t, Ui.weight(this, 1, 6));
        Button b = Ui.button(this, action, R.drawable.btn_ghost, R.color.ink2);
        b.setId(id);
        b.setTextSize(12);
        b.setMinHeight(Ui.dp(this, 34));
        b.setMinimumHeight(Ui.dp(this, 34));
        b.setOnClickListener(l);
        r.addView(b, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, Ui.dp(this, 34)));
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

    // ------------------------------------------------------------------ actions

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
            title = "מגבלה של " + Ui.words(value) + " ביום";
            msg = "נכנס לתוקף מיד. אחרי האישור לא תוכל להגדיל או לבטל אותה במשך 24 שעות.";
        } else {
            title = "להגדיל ל-" + Ui.words(value) + "?";
            msg = "ההגדלה תיכנס לתוקף רק בעוד 24 שעות. אפשר לבטל את הבקשה בכל רגע.";
        }
        if (!GuardService.isRunning()) msg += "\n\nשים לב: שירות הנגישות כבוי, ולכן החסימה לא תעבוד עד שתפעיל אותו.";
        new AlertDialog.Builder(this)
                .setTitle(title)
                .setMessage(msg)
                .setPositiveButton("אישור", (d, w) -> {
                    boolean now2 = Store.policy(this).requestLimit(value, Store.now(this));
                    Store.save(this);
                    Toast.makeText(this, now2 ? "נקבע. בהצלחה." : "נרשם. ייכנס לתוקף בעוד 24 שעות.", Toast.LENGTH_SHORT).show();
                    render();
                })
                .setNegativeButton("ביטול", null)
                .show();
    }

    private void confirmLock(long until, String label) {
        String msg = "מעכשיו ועד " + Ui.when(Store.toWall(this, until), System.currentTimeMillis())
                + " – רק שיחות, הודעות ומוביט. אין כפתור ביטול.";
        if (!GuardService.isRunning()) msg += "\n\nשירות הנגישות כבוי – הנעילה לא תיאכף עד שתפעיל אותו.";
        new AlertDialog.Builder(this)
                .setTitle("לנעול " + label + "?")
                .setMessage(msg)
                .setPositiveButton("נעל", (d, w) -> {
                    Store.policy(this).lockUntil(until, Store.now(this));
                    Store.save(this);
                    render();
                })
                .setNegativeButton("ביטול", null)
                .show();
    }

    private void confirmSocialOff() {
        Policy p = Store.policy(this);
        boolean committed = p.committed(Store.now(this));
        new AlertDialog.Builder(this)
                .setTitle("לכבות את החסימה?")
                .setMessage(committed ? "הכיבוי ייכנס לתוקף רק בעוד 24 שעות." : "אין מגבלה פעילה, אז זה ייכנס לתוקף מיד.")
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
        Policy p = Store.policy(this);
        boolean immediate = p.requestAllow(pkg, Store.now(this));
        Store.save(this);
        Toast.makeText(this, immediate ? "נוסף" : "יתווסף בעוד 24 שעות", Toast.LENGTH_SHORT).show();
        render();
    }

    private boolean adminActive() {
        DevicePolicyManager dpm = (DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
        return dpm != null && dpm.isAdminActive(new ComponentName(this, AdminReceiver.class));
    }

    private void safeStart(Intent i) {
        try {
            startActivity(i);
        } catch (RuntimeException e) {
            Toast.makeText(this, "לא הצלחתי לפתוח את ההגדרות", Toast.LENGTH_SHORT).show();
        }
    }
}

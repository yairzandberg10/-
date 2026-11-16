package com.ogen.app;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.provider.Telephony;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** Full-screen "not now" page shown whenever something is blocked. */
public class BlockActivity extends Activity {
    static final String EXTRA_REASON = "reason";
    static final int R_LOCKED = 1, R_TAMPER = 2, R_STORE = 3, R_SOCIAL = 4, R_SITE = 5;

    private final Handler handler = new Handler();
    private TextView big, sub;
    private int reason;

    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            update();
            handler.postDelayed(this, 20_000);
        }
    };

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        reason = getIntent().getIntExtra(EXTRA_REASON, R_LOCKED);
        build();
    }

    @Override protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        reason = i.getIntExtra(EXTRA_REASON, R_LOCKED);
        build();
    }

    @Override protected void onResume() {
        super.onResume();
        handler.post(refresh);
    }

    @Override protected void onPause() {
        handler.removeCallbacks(refresh);
        super.onPause();
    }

    private void build() {
        LinearLayout root = Ui.col(this);
        int pad = Ui.dp(this, 20);
        root.setPadding(pad, Ui.dp(this, 28), pad, pad);

        ImageView mark = new ImageView(this);
        mark.setImageResource(R.drawable.ic_anchor_light);
        root.addView(mark, new LinearLayout.LayoutParams(Ui.dp(this, 28), Ui.dp(this, 28)));

        TextView title = Ui.text(this, title(), 22, R.color.on_night, Ui.MEDIUM);
        root.addView(title, Ui.top(this, 18));

        big = Ui.text(this, "", 46, R.color.on_night, Ui.LIGHT);
        big.setIncludeFontPadding(false);
        root.addView(big, Ui.top(this, 10));

        sub = Ui.text(this, "", 14, R.color.on_night_muted, Ui.REGULAR);
        root.addView(sub, Ui.top(this, 6));

        TextView body = Ui.text(this, body(), 14, R.color.on_night_muted, Ui.REGULAR);
        root.addView(body, Ui.top(this, 16));

        // What still works
        LinearLayout actions = Ui.col(this);
        Button call = Ui.night(this, "שיחות");
        call.setOnClickListener(v -> open(new Intent(Intent.ACTION_DIAL)));
        Button sms = Ui.night(this, "הודעות");
        sms.setOnClickListener(v -> openSms());
        LinearLayout r1 = Ui.row(this);
        r1.addView(call, Ui.weight(this, 1, 8));
        r1.addView(sms, Ui.weight(this, 1, 0));
        actions.addView(r1, Ui.match());

        LinearLayout r2 = Ui.row(this);
        if (installed(Rules.MOOVIT)) {
            Button moovit = Ui.night(this, "מוביט");
            moovit.setOnClickListener(v -> open(getPackageManager().getLaunchIntentForPackage(Rules.MOOVIT)));
            r2.addView(moovit, Ui.weight(this, 1, 8));
        }
        Button home = Ui.button(this, "למסך הבית", R.drawable.btn_ghost, R.color.ink);
        home.setOnClickListener(v -> goHome());
        r2.addView(home, Ui.weight(this, 1, 0));
        actions.addView(r2, Ui.top(this, 8));
        root.addView(actions, Ui.top(this, 22));

        ScrollView sv = new ScrollView(this);
        sv.setFillViewport(true);
        sv.addView(root, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(sv);
        home.requestFocus();
        update();
    }

    private String title() {
        switch (reason) {
            case R_TAMPER: return "המסך הזה סגור עכשיו";
            case R_STORE: return "התקנות סגורות";
            case R_SOCIAL: return "לא עכשיו";
            case R_SITE: return "האתר הזה חסום";
            default: return "הטלפון נעול לשימוש חופשי";
        }
    }

    private String body() {
        switch (reason) {
            case R_TAMPER: return "בזמן מגבלה אי אפשר לשנות שעה, לכבות את עוגן או להסיר אותו. זה בדיוק מה שהבטחת לעצמך.";
            case R_STORE: return "כל עוד יש מגבלה פעילה אי אפשר להתקין או להסיר אפליקציות.";
            case R_SOCIAL: return "רשתות חברתיות ווידאו חסומים כל עוד יש מגבלה פעילה.";
            case R_SITE: return "אתרים של רשתות חברתיות ווידאו חסומים בדפדפן כל עוד יש מגבלה פעילה.";
            default: return "עד שהנעילה תיגמר אפשר רק להתקשר, לשלוח הודעות ולהשתמש במוביט.";
        }
    }

    private void update() {
        Policy p = Store.policy(this);
        long now = Store.now(this);
        p.tick(now);
        long end = p.lockEnds(now);
        if (end > now) {
            big.setText(Ui.hm(end - now));
            sub.setText("נותרו · נפתח " + Ui.when(Store.toWall(this, end), System.currentTimeMillis()));
            big.setVisibility(View.VISIBLE);
        } else if (p.committed(now)) {
            if (p.limitMs != Policy.NONE) {
                big.setText(Ui.hm(p.remainingMs()));
                sub.setText("זמן חופשי שנשאר להיום");
            } else {
                big.setVisibility(View.GONE);
                sub.setText("");
            }
        } else {
            goHome();
        }
    }

    private boolean installed(String pkg) {
        try {
            getPackageManager().getPackageInfo(pkg, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    private void openSms() {
        String pkg = null;
        try { pkg = Telephony.Sms.getDefaultSmsPackage(this); } catch (RuntimeException ignored) { }
        Intent i = pkg == null ? null : getPackageManager().getLaunchIntentForPackage(pkg);
        if (i == null) i = new Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:"));
        open(i);
    }

    private void open(Intent i) {
        if (i == null) return;
        try {
            startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            finish();
        } catch (RuntimeException ignored) { }
    }

    private void goHome() {
        Intent h = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try { startActivity(h); } catch (RuntimeException ignored) { }
        finish();
    }

    @Override public boolean onKeyDown(int code, KeyEvent e) {
        if (code == KeyEvent.KEYCODE_BACK) {
            goHome();
            return true;
        }
        return super.onKeyDown(code, e);
    }

    @Override public void onBackPressed() {
        goHome();
    }
}

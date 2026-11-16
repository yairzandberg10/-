package com.ogen.app;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import java.text.Collator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Pick one installed app to allow during a lockdown (social, browsers and stores are not offered). */
public class AppPickerActivity extends Activity {
    static final String EXTRA_PKG = "pkg";

    private static final class App {
        final String pkg, label;
        final ResolveInfo info;
        App(String pkg, String label, ResolveInfo info) { this.pkg = pkg; this.label = label; this.info = info; }
    }

    private final List<App> apps = new ArrayList<>();

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        PackageManager pm = getPackageManager();
        Policy p = Store.policy(this);
        Set<String> seen = new HashSet<>();
        List<ResolveInfo> list = pm.queryIntentActivities(
                new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0);
        for (ResolveInfo ri : list) {
            String pkg = ri.activityInfo.packageName;
            if (!seen.add(pkg)) continue;
            if (pkg.equals(getPackageName()) || Rules.isSocial(pkg) || Rules.isStore(pkg, null)
                    || Rules.isSettings(pkg) || Rules.isBrowser(this, pkg)) continue;
            if (Rules.allowedInLock(this, p, pkg) || p.pendingAllow(pkg) != null) continue;
            apps.add(new App(pkg, ri.loadLabel(pm).toString(), ri));
        }
        final Collator col = Collator.getInstance();
        Collections.sort(apps, (a, c) -> col.compare(a.label, c.label));

        LinearLayout root = Ui.col(this);
        root.setBackgroundColor(Ui.color(this, R.color.paper));
        int side = Ui.dp(this, 12);
        TextView title = Ui.text(this, "איזו אפליקציה לאשר?", 18, R.color.ink, Ui.MEDIUM);
        title.setPadding(side + Ui.dp(this, 4), Ui.dp(this, 14), side, Ui.dp(this, 2));
        root.addView(title, Ui.match());
        TextView sub = Ui.text(this, p.committed(Store.now(this)) ? "יאושר בעוד 24 שעות" : "יאושר מיד", 12, R.color.muted, Ui.REGULAR);
        sub.setPadding(side + Ui.dp(this, 4), 0, side, Ui.dp(this, 8));
        root.addView(sub, Ui.match());

        ListView lv = new ListView(this);
        lv.setDivider(null);
        lv.setPadding(side, 0, side, side);
        lv.setClipToPadding(false);
        lv.setItemsCanFocus(false);
        lv.setSelector(R.drawable.row_bg);
        lv.setDrawSelectorOnTop(false);
        lv.setAdapter(new Adapter(pm));
        lv.setOnItemClickListener((parent, view, pos, id) -> {
            setResult(RESULT_OK, new Intent().putExtra(EXTRA_PKG, apps.get(pos).pkg));
            finish();
        });
        root.addView(lv, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        if (apps.isEmpty()) {
            TextView empty = Ui.text(this, "אין אפליקציות נוספות להוספה.", 14, R.color.muted, Ui.REGULAR);
            empty.setPadding(side + Ui.dp(this, 4), Ui.dp(this, 16), side, 0);
            root.addView(empty, 2, Ui.match());
        }
        setContentView(root);
    }

    private final class Adapter extends BaseAdapter {
        private final PackageManager pm;
        Adapter(PackageManager pm) { this.pm = pm; }

        @Override public int getCount() { return apps.size(); }
        @Override public Object getItem(int i) { return apps.get(i); }
        @Override public long getItemId(int i) { return i; }

        @Override public View getView(int i, View convert, ViewGroup parent) {
            LinearLayout r;
            ImageView icon;
            TextView name;
            if (convert == null) {
                r = Ui.row(AppPickerActivity.this);
                r.setPadding(Ui.dp(AppPickerActivity.this, 8), Ui.dp(AppPickerActivity.this, 8),
                        Ui.dp(AppPickerActivity.this, 8), Ui.dp(AppPickerActivity.this, 8));
                icon = new ImageView(AppPickerActivity.this);
                int s = Ui.dp(AppPickerActivity.this, 32);
                r.addView(icon, new LinearLayout.LayoutParams(s, s));
                name = Ui.text(AppPickerActivity.this, "", 15, R.color.ink, Ui.REGULAR);
                name.setSingleLine(true);
                name.setEllipsize(TextUtils.TruncateAt.END);
                name.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1);
                lp.setMarginStart(Ui.dp(AppPickerActivity.this, 12));
                r.addView(name, lp);
                r.setTag(new Object[]{icon, name});
            } else {
                r = (LinearLayout) convert;
                Object[] tag = (Object[]) r.getTag();
                icon = (ImageView) tag[0];
                name = (TextView) tag[1];
            }
            App a = apps.get(i);
            name.setText(a.label);
            Drawable d;
            try { d = a.info.loadIcon(pm); } catch (RuntimeException e) { d = null; }
            icon.setImageDrawable(d);
            return r;
        }
    }
}

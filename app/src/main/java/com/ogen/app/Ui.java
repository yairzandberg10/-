package com.ogen.app;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Calendar;

/** Tiny view kit so every screen shares spacing, type and focus behaviour. */
final class Ui {
    private Ui() {}

    static final Typeface MEDIUM = Typeface.create("sans-serif-medium", Typeface.NORMAL);
    static final Typeface LIGHT = Typeface.create("sans-serif-light", Typeface.NORMAL);
    static final Typeface REGULAR = Typeface.create("sans-serif", Typeface.NORMAL);

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    static int color(Context c, int res) {
        return c.getResources().getColor(res);
    }

    static TextView text(Context c, CharSequence s, float sp, int colorRes, Typeface tf) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(color(c, colorRes));
        t.setTypeface(tf);
        t.setLineSpacing(0, 1.12f);
        t.setTextDirection(View.TEXT_DIRECTION_LOCALE);
        t.setGravity(Gravity.START);
        return t;
    }

    /** Small all-caps-style label above a section. */
    static TextView label(Context c, CharSequence s) {
        TextView t = text(c, s, 12, R.color.muted, MEDIUM);
        t.setLetterSpacing(0.04f);
        return t;
    }

    static Button button(Context c, CharSequence s, int bgRes, int textColorRes) {
        Button b = new Button(c);
        b.setText(s);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        b.setTypeface(MEDIUM);
        b.setTextColor(color(c, textColorRes));
        b.setBackgroundResource(bgRes);
        b.setMinHeight(dp(c, 44));
        b.setMinimumHeight(dp(c, 44));
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setPadding(dp(c, 12), 0, dp(c, 12), 0);
        b.setStateListAnimator(null);
        b.setFocusable(true);
        b.setSingleLine(true);
        b.setEllipsize(TextUtils.TruncateAt.END);
        return b;
    }

    static Button primary(Context c, CharSequence s) { return button(c, s, R.drawable.btn_primary, R.color.card); }
    static Button ghost(Context c, CharSequence s) { return button(c, s, R.drawable.btn_ghost, R.color.ink); }
    static Button danger(Context c, CharSequence s) { return button(c, s, R.drawable.btn_danger, R.color.card); }
    static Button night(Context c, CharSequence s) { return button(c, s, R.drawable.btn_night, R.color.on_night); }

    static LinearLayout col(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    static LinearLayout row(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setGravity(Gravity.CENTER_VERTICAL);
        return l;
    }

    static LinearLayout card(Context c) {
        LinearLayout l = col(c);
        l.setBackgroundResource(R.drawable.bg_card);
        int p = dp(c, 14);
        l.setPadding(p, dp(c, 12), p, p);
        return l;
    }

    static LinearLayout.LayoutParams wrap() {
        return new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    static LinearLayout.LayoutParams match() {
        return new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
    }

    static LinearLayout.LayoutParams weight(Context c, float w, int marginEndDp) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, w);
        lp.setMarginEnd(dp(c, marginEndDp));
        return lp;
    }

    static LinearLayout.LayoutParams top(Context c, int dpTop) {
        LinearLayout.LayoutParams lp = match();
        lp.topMargin = dp(c, dpTop);
        return lp;
    }

    static View hairline(Context c) {
        View v = new View(c);
        v.setBackgroundColor(color(c, R.color.line));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, Math.max(1, dp(c, 0.7f)));
        lp.setMargins(dp(c, 12), 0, dp(c, 12), 0);
        v.setLayoutParams(lp);
        return v;
    }

    // ---- formatting ----

    /** 1:05 style (hours:minutes). */
    static String hm(long ms) {
        if (ms < 0) ms = 0;
        long totalMin = (ms + 59_999) / 60_000;
        return (totalMin / 60) + ":" + pad(totalMin % 60);
    }

    /** "שעה ו-20 דק׳", "45 דק׳", "3 שעות". */
    static String words(long ms) {
        long m = Math.max(0, (ms + 59_999) / 60_000);
        long h = m / 60, r = m % 60;
        String hs = h == 0 ? "" : h == 1 ? "שעה" : h == 2 ? "שעתיים" : h + " שעות";
        if (h == 0) return r + " דק׳";
        if (r == 0) return hs;
        return hs + " ו-" + r + " דק׳";
    }

    static String clock(long wall) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(wall);
        return pad(c.get(Calendar.HOUR_OF_DAY)) + ":" + pad(c.get(Calendar.MINUTE));
    }

    /** "היום 14:30" / "מחר 09:00" / "16.11 09:00". */
    static String when(long wall, long nowWall) {
        long d0 = Policy.dayStart(nowWall);
        long d = Policy.dayStart(wall);
        String day;
        if (d == d0) day = "היום";
        else if (d == Policy.nextDayStart(nowWall)) day = "מחר";
        else {
            Calendar c = Calendar.getInstance();
            c.setTimeInMillis(wall);
            day = c.get(Calendar.DAY_OF_MONTH) + "." + (c.get(Calendar.MONTH) + 1);
        }
        return day + " ב-" + clock(wall);
    }

    private static String pad(long v) {
        return v < 10 ? "0" + v : String.valueOf(v);
    }

    /** Thin progress track. Fills from the reading start (right side in Hebrew). */
    static final class Bar extends View {
        private final Paint track = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF r = new RectF();
        private float value;

        Bar(Context c, int trackColor, int fillColor) {
            super(c);
            track.setColor(trackColor);
            fill.setColor(fillColor);
        }

        void set(float v) {
            value = Math.max(0, Math.min(1, v));
            invalidate();
        }

        @Override protected void onMeasure(int w, int h) {
            setMeasuredDimension(MeasureSpec.getSize(w), dp(getContext(), 6));
        }

        @Override protected void onDraw(Canvas cv) {
            float h = getHeight(), w = getWidth(), rad = h / 2f;
            r.set(0, 0, w, h);
            cv.drawRoundRect(r, rad, rad, track);
            if (value <= 0) return;
            float fw = Math.max(h, w * value);
            boolean rtl = getLayoutDirection() == LAYOUT_DIRECTION_RTL;
            if (rtl) r.set(w - fw, 0, w, h); else r.set(0, 0, fw, h);
            cv.drawRoundRect(r, rad, rad, fill);
        }
    }
}

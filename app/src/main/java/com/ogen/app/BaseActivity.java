package com.ogen.app;

import android.app.Activity;
import android.content.Context;
import android.content.res.Configuration;
import android.os.Bundle;
import android.view.View;

import java.util.Locale;

/** Every screen is Hebrew + right-to-left, whatever language the phone is set to. */
public abstract class BaseActivity extends Activity {
    static final Locale HE = new Locale("iw");

    @Override protected void attachBaseContext(Context base) {
        Configuration c = new Configuration(base.getResources().getConfiguration());
        c.setLocale(HE);
        c.setLayoutDirection(HE);
        super.attachBaseContext(base.createConfigurationContext(c));
    }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().getDecorView().setLayoutDirection(View.LAYOUT_DIRECTION_RTL);
    }
}

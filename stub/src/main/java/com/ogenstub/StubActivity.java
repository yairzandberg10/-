package com.ogenstub;

public class StubActivity extends android.app.Activity {
    @Override protected void onCreate(android.os.Bundle b) {
        super.onCreate(b);
        android.widget.TextView t = new android.widget.TextView(this);
        t.setText("INSTAGRAM STUB — if you can see this, blocking failed");
        t.setTextSize(22);
        setContentView(t);
    }
}

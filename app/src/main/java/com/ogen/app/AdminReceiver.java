package com.ogen.app;

import android.app.admin.DeviceAdminReceiver;
import android.content.Context;
import android.content.Intent;

public class AdminReceiver extends DeviceAdminReceiver {
    @Override public CharSequence onDisableRequested(Context c, Intent i) {
        return "עוגן מגן עליך מפני עצמך. אם יש מגבלה פעילה – אי אפשר לבטל עכשיו.";
    }
}

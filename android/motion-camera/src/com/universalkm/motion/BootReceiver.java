package com.universalkm.motion;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * After a restart or an update, turns the camera back on if it was on (design D3). The "tap to turn it back
 * on" notification goes up first; the service removes it once it runs, so it stays only when Android did not
 * let the camera start without the user.
 */
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent intent) {
        if (!Settings.load(c).on) return;
        Notifications.showResume(c);
        try {
            c.startActivity(new Intent(c, ControlActivity.class).putExtra("on", true)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        } catch (RuntimeException e) {
            Log.w(ClipStore.TAG, "boot start", e);
        }
    }
}

package com.universalkm.motion;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

/**
 * Invisible entry for commands (design D3, D5): saves the settings it is given and starts or stops the
 * camera service. A visible activity may start a camera foreground service; a broadcast receiver may not.
 * Only adb (android.permission.DUMP) and this app itself can open it.
 */
public final class ControlActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Settings s = Settings.load(this);
        s.apply(getIntent().getExtras());
        s.save(this);
        // `--es live back|front|both|none`: the live picture for the Mac (design D11); not saved.
        String live = getIntent().getStringExtra("live");
        boolean watch = live != null ? !"none".equals(live) : MotionService.liveRequested;
        try {
            if (s.on || watch) {
                Intent i = new Intent(this, MotionService.class).setAction(MotionService.ACTION_START);
                if (live != null) i.putExtra("live", live);
                // Test hook (tasks 3.x): `--ei simulate N` counts the next N seconds as motion.
                int simulate = getIntent().getIntExtra("simulate", 0);
                if (simulate > 0) i.putExtra("simulate", simulate);
                startForegroundService(i);
            } else if (MotionService.running) {
                startService(new Intent(this, MotionService.class).setAction(MotionService.ACTION_STOP));
            }
        } catch (RuntimeException e) {
            Log.w(ClipStore.TAG, "control", e);
            Notifications.showResume(this);
        }
        finish();
    }
}

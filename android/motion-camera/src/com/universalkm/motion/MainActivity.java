package com.universalkm.motion;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.format.Formatter;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.Switch;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;

/** What opens from the launcher: the switch and the state; settings come from the Mac. */
public final class MainActivity extends Activity {
    private Switch toggle;
    private TextView stateView, clipsView;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private boolean updating;
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            refresh();
            ui.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad * 2, pad, pad);
        toggle = new Switch(this);
        toggle.setText(R.string.switch_label);
        toggle.setTextSize(20);
        toggle.setOnCheckedChangeListener((b, on) -> {
            if (!updating) setOn(on);
        });
        stateView = new TextView(this);
        stateView.setTextSize(16);
        stateView.setPadding(0, pad / 2, 0, 0);
        clipsView = new TextView(this);
        clipsView.setTextSize(14);
        TextView hint = new TextView(this);
        hint.setText(R.string.hint);
        hint.setPadding(0, pad, 0, 0);
        hint.setGravity(Gravity.START);
        root.addView(toggle);
        root.addView(stateView);
        root.addView(clipsView);
        root.addView(hint);
        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        ui.post(tick);
    }

    @Override
    protected void onPause() {
        ui.removeCallbacks(tick);
        super.onPause();
    }

    private void setOn(boolean on) {
        Settings s = Settings.load(this);
        s.on = on;
        s.save(this);
        if (on) {
            List<String> missing = new ArrayList<>();
            for (String p : new String[]{Manifest.permission.CAMERA, Manifest.permission.POST_NOTIFICATIONS})
                if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) missing.add(p);
            if (!missing.isEmpty()) requestPermissions(missing.toArray(new String[0]), 1);
            startForegroundService(new Intent(this, MotionService.class).setAction(MotionService.ACTION_START));
        } else if (MotionService.running) {
            startService(new Intent(this, MotionService.class).setAction(MotionService.ACTION_STOP));
        }
        refresh();
    }

    private void refresh() {
        Settings s = Settings.load(this);
        updating = true;
        toggle.setChecked(s.on);
        updating = false;
        stateView.setText(Notifications.stateText(this, StatusProvider.currentState(this, s)));
        new Thread(() -> {
            long[] u = new ClipStore(this).usage();
            String text = getString(R.string.clips, (int) u[0], Formatter.formatShortFileSize(this, u[1]));
            ui.post(() -> clipsView.setText(text));
        }).start();
    }
}

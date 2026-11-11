package com.universalkm.motion;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.BatteryManager;

/**
 * State for the Mac (design D5): {@code adb shell content query --uri content://com.universalkm.motion/status}
 * prints one row. Readable only with android.permission.DUMP (adb), not by other apps.
 */
public final class StatusProvider extends ContentProvider {
    static final String[] COLUMNS = {"state", "on", "clips", "bytes", "free", "battery", "charging", "version",
            "sens", "stop", "cam", "q", "limitMB", "both", "active", "live"};

    @Override
    public boolean onCreate() {
        return true;
    }

    static String currentState(Context c, Settings s) {
        if (MotionService.running) return MotionService.state;
        return s.on ? "stopped" : "off";
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        Context c = getContext();
        Settings s = Settings.load(c);
        long[] usage = new ClipStore(c).usage();
        int battery = MotionService.batteryPercent;
        boolean charging = MotionService.charging;
        if (!MotionService.running) {
            Intent b = c.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (b != null) {
                int level = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
                int scale = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
                battery = level < 0 ? -1 : level * 100 / Math.max(1, scale);
                charging = b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0;
            }
        }
        long version = 0;
        try {
            version = c.getPackageManager().getPackageInfo(c.getPackageName(), 0).getLongVersionCode();
        } catch (PackageManager.NameNotFoundException ignored) {
        }
        // Whether "both" can work here (design D10), and which cameras record now.
        boolean both = MotionService.concurrentPair(c.getSystemService(android.hardware.camera2.CameraManager.class)) != null;
        String active = MotionService.running ? MotionService.active : "";
        String live = MotionService.running ? MotionService.liveOpen : "";
        MatrixCursor m = new MatrixCursor(COLUMNS, 1);
        m.addRow(new Object[]{currentState(c, s), s.on ? 1 : 0, usage[0], usage[1], ClipStore.freeBytes(), battery,
                charging ? 1 : 0, version, s.sens, s.stopSec, s.cam, s.quality, s.limitMB, both ? 1 : 0,
                active.isEmpty() ? "-" : active, live.isEmpty() ? "-" : live});
        return m;
    }

    @Override
    public String getType(Uri uri) {
        return "vnd.android.cursor.item/vnd.universalkm.motion.status";
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        return 0;
    }
}

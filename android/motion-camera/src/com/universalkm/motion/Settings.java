package com.universalkm.motion;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Bundle;

/** What the Mac sets (design D5); kept on the device so the camera works without the Mac. */
final class Settings {
    private static final String PREFS = "motion";

    boolean on;
    String sens = "mid";       // low | mid | high
    int stopSec = 10;          // 5–60
    String cam = "back";       // back | front
    int quality = 720;         // 720 | 1080
    long limitMB = 4096;

    static Settings load(Context c) {
        SharedPreferences p = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Settings s = new Settings();
        s.on = p.getBoolean("on", false);
        s.sens = p.getString("sens", s.sens);
        s.stopSec = p.getInt("stop", s.stopSec);
        s.cam = p.getString("cam", s.cam);
        s.quality = p.getInt("q", s.quality);
        s.limitMB = p.getLong("limitMB", s.limitMB);
        return s;
    }

    void save(Context c) {
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean("on", on).putString("sens", sens).putInt("stop", stopSec).putString("cam", cam)
                .putInt("q", quality).putLong("limitMB", limitMB).commit();
    }

    /** Takes the keys the Mac sends (`--es sens mid --ei stop 10 --es cam back --ei q 720 --el limitMB 4096`). */
    void apply(Bundle e) {
        if (e == null) return;
        if (e.containsKey("on")) on = e.getBoolean("on");
        String v = e.getString("sens");
        if ("low".equals(v) || "mid".equals(v) || "high".equals(v)) sens = v;
        if (e.containsKey("stop")) stopSec = clamp(e.getInt("stop"), 5, 60);
        v = e.getString("cam");
        if ("back".equals(v) || "front".equals(v)) cam = v;
        if (e.containsKey("q")) quality = e.getInt("q") >= 1080 ? 1080 : 720;
        if (e.containsKey("limitMB")) limitMB = Math.max(100, e.getLong("limitMB"));
    }

    /** The camera has to be reopened for these. */
    boolean pipelineDiffers(Settings o) {
        return !cam.equals(o.cam) || quality != o.quality;
    }

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }
}

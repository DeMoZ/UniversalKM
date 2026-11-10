package com.universalkm.motion;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

/** The ongoing camera notification and the "tap to turn it back on" one (design D3). */
final class Notifications {
    static final int CAMERA_ID = 1;
    static final int RESUME_ID = 2;
    private static final String CH_CAMERA = "camera";
    private static final String CH_RESUME = "resume";

    static void channels(Context c) {
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CH_CAMERA, c.getString(R.string.channel_camera),
                NotificationManager.IMPORTANCE_LOW));
        nm.createNotificationChannel(new NotificationChannel(CH_RESUME, c.getString(R.string.channel_resume),
                NotificationManager.IMPORTANCE_HIGH));
    }

    static String stateText(Context c, String state) {
        switch (state) {
            case "starting": return c.getString(R.string.state_starting);
            case "watching": return c.getString(R.string.state_watching);
            case "recording": return c.getString(R.string.state_recording);
            case "no_camera": return c.getString(R.string.state_no_camera);
            case "no_permission": return c.getString(R.string.state_no_permission);
            case "low_space": return c.getString(R.string.state_low_space);
            case "battery_low": return c.getString(R.string.state_battery_low);
            case "stopped": return c.getString(R.string.state_stopped);
            case "error": return c.getString(R.string.state_error);
            default: return c.getString(R.string.state_off);
        }
    }

    static Notification camera(Context c, String state) {
        PendingIntent open = PendingIntent.getActivity(c, 0, new Intent(c, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getService(c, 1,
                new Intent(c, MotionService.class).setAction(MotionService.ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(c, CH_CAMERA)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle(c.getString(R.string.switch_label))
                .setContentText(stateText(c, state))
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                .addAction(new Notification.Action.Builder(null, c.getString(R.string.turn_off), stop).build())
                .build();
    }

    static void updateCamera(Context c, String state) {
        c.getSystemService(NotificationManager.class).notify(CAMERA_ID, camera(c, state));
    }

    static void showResume(Context c) {
        channels(c);
        Intent i = new Intent(c, ControlActivity.class).putExtra("on", true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        PendingIntent tap = PendingIntent.getActivity(c, 2, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification n = new Notification.Builder(c, CH_RESUME)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle(c.getString(R.string.resume_title))
                .setContentText(c.getString(R.string.resume_text))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build();
        c.getSystemService(NotificationManager.class).notify(RESUME_ID, n);
    }

    static void cancelResume(Context c) {
        c.getSystemService(NotificationManager.class).cancel(RESUME_ID);
    }
}

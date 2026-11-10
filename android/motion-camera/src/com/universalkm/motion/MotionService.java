package com.universalkm.motion;

import android.Manifest;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.os.BatteryManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;

/**
 * The camera service (design D3, D10): the notification, the wake lock, battery and space checks, and one
 * {@link CameraPipeline} per camera in use — the rear or the front one, or both where the device can stream
 * from both at once. Everything runs on one handler thread.
 */
public final class MotionService extends Service implements CameraPipeline.Host {
    static final String TAG = ClipStore.TAG;
    static final String ACTION_START = "com.universalkm.motion.START";
    static final String ACTION_STOP = "com.universalkm.motion.STOP";

    private static final long S = 1_000_000L;
    private static final long RETRY_MS = 10_000;
    private static final long SPACE_CHECK_MS = 30_000;

    // Read by StatusProvider and MainActivity.
    static volatile boolean running;
    static volatile String state = "off";
    static volatile int batteryPercent = -1;
    static volatile boolean charging;
    /** Cameras recording now ("rear", "front"), for the state line. */
    static volatile String active = "";

    private HandlerThread thread;
    private Handler h;
    private Settings settings;
    private PowerManager.WakeLock wakeLock;
    private ClipStore store;
    private CameraManager cameraManager;
    private final List<CameraPipeline> pipelines = new ArrayList<>();
    private boolean reopenWhenIdle;
    private boolean batteryLow;
    private boolean lowSpace;
    private boolean noPermission;
    private volatile int deviceRotation;
    private volatile long simulateUntilMonoUs;
    private SensorManager sensors;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : String.valueOf(intent.getAction());
        if (ACTION_STOP.equals(action)) {
            // Off from any side is off for good: the setting stays off, no restart after a reboot.
            Settings s = Settings.load(this);
            s.on = false;
            s.save(this);
            stopEverything();
            return START_NOT_STICKY;
        }
        // Every start request is answered with startForeground (startForegroundService needs it each time).
        try {
            Notifications.channels(this);
            startForeground(Notifications.CAMERA_ID, Notifications.camera(this, running ? state : "starting"),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA);
        } catch (RuntimeException e) {
            // Android refused a camera service from the background (design D3): ask the user to tap.
            Log.w(TAG, "startForeground refused", e);
            state = "error";
            Notifications.showResume(this);
            stopSelf();
            return START_NOT_STICKY;
        }
        Notifications.cancelResume(this);
        int simulate = intent == null ? 0 : intent.getIntExtra("simulate", 0);
        if (simulate > 0) {
            simulateUntilMonoUs = System.nanoTime() / 1000 + Math.min(simulate, 1800) * S;
            Log.i(TAG, "simulated motion for " + simulate + " s");
        }
        if (!running) {
            start();
        } else {
            h.post(this::reloadSettings);
        }
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (running) shutdown();
        super.onDestroy();
    }

    private void start() {
        running = true;
        settings = Settings.load(this);
        store = new ClipStore(this);
        cameraManager = getSystemService(CameraManager.class);
        thread = new HandlerThread("motion");
        thread.start();
        h = new Handler(thread.getLooper());
        PowerManager pm = getSystemService(PowerManager.class);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "UKMMotion:camera");
        wakeLock.acquire();
        registerReceiver(battery, new IntentFilter(Intent.ACTION_BATTERY_CHANGED), null, h);
        sensors = getSystemService(SensorManager.class);
        Sensor acc = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        if (acc != null) sensors.registerListener(gravity, acc, SensorManager.SENSOR_DELAY_NORMAL, h);
        h.post(() -> {
            store.recoverPending();
            checkSpace();
            openCameras();
        });
        h.postDelayed(spaceCheck, SPACE_CHECK_MS);
        h.postDelayed(heartbeat, 60_000);
    }

    private void stopEverything() {
        if (running) shutdown();
        state = "off";
        active = "";
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void shutdown() {
        running = false;
        final Handler handler = h;
        if (handler != null) {
            // Close the clips and the cameras on their own thread, then let the thread go.
            final Object done = new Object();
            final boolean[] finished = {false};
            handler.post(() -> {
                closeCameras();
                synchronized (done) {
                    finished[0] = true;
                    done.notifyAll();
                }
            });
            synchronized (done) {
                long until = SystemClock.uptimeMillis() + 3000;
                while (!finished[0] && SystemClock.uptimeMillis() < until) {
                    try {
                        done.wait(500);
                    } catch (InterruptedException e) {
                        break;
                    }
                }
            }
            // Renames of just-closed clips are posted for later: run them now (ClipStore.finish).
            handler.removeCallbacksAndMessages(null);
            store.renameNow();
        }
        try {
            unregisterReceiver(battery);
        } catch (RuntimeException ignored) {
        }
        if (sensors != null) sensors.unregisterListener(gravity);
        if (thread != null) thread.quitSafely();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        state = "off";
        active = "";
    }

    // MARK: cameras (design D10)

    /** {rear id, front id} that the device can stream from at the same time; null if it cannot. */
    static String[] concurrentPair(CameraManager cm) {
        try {
            for (Set<String> set : cm.getConcurrentCameraIds()) {
                String rear = null, front = null;
                for (String id : set) {
                    Integer f = cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING);
                    if (f == null) continue;
                    if (f == CameraCharacteristics.LENS_FACING_BACK && rear == null) rear = id;
                    if (f == CameraCharacteristics.LENS_FACING_FRONT && front == null) front = id;
                }
                if (rear != null && front != null) return new String[]{rear, front};
            }
        } catch (CameraAccessException | RuntimeException e) {
            Log.w(TAG, "concurrent cameras", e);
        }
        return null;
    }

    private static String firstCamera(CameraManager cm, boolean front) throws CameraAccessException {
        String fallback = null;
        for (String id : cm.getCameraIdList()) {
            Integer f = cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING);
            if (f == null) continue;
            boolean isFront = f == CameraCharacteristics.LENS_FACING_FRONT;
            if (isFront == front) return id;
            if (fallback == null) fallback = id;
        }
        return fallback;
    }

    private void openCameras() {
        if (!running || !pipelines.isEmpty()) return;
        if (batteryLow) {
            changed();
            return;
        }
        noPermission = checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED;
        if (noPermission) {
            changed();
            h.postDelayed(this::openCameras, RETRY_MS);
            return;
        }
        try {
            if ("both".equals(settings.cam)) {
                String[] pair = concurrentPair(cameraManager);
                if (pair != null) {
                    // Two cameras at once: Android guarantees streams up to 720p for each (design D10).
                    pipelines.add(new CameraPipeline(this, pair[0], false, "rear", 720));
                    pipelines.add(new CameraPipeline(this, pair[1], true, "front", 720));
                } else {
                    Log.w(TAG, "both cameras asked, but this device cannot stream from both at once: rear only");
                }
            }
            if (pipelines.isEmpty()) {
                boolean front = "front".equals(settings.cam);
                String id = firstCamera(cameraManager, front);
                if (id == null) throw new CameraAccessException(CameraAccessException.CAMERA_ERROR, "no camera");
                Integer f = cameraManager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING);
                pipelines.add(new CameraPipeline(this, id, f != null && f == CameraCharacteristics.LENS_FACING_FRONT,
                        null, settings.quality));
            }
        } catch (CameraAccessException | RuntimeException e) {
            Log.w(TAG, "cameras", e);
            pipelines.clear();
            changed();
            h.postDelayed(this::openCameras, RETRY_MS);
            return;
        }
        for (CameraPipeline p : pipelines) p.open();
        changed();
    }

    private void closeCameras() {
        for (CameraPipeline p : pipelines) p.close();
        pipelines.clear();
    }

    private boolean anyRecording() {
        for (CameraPipeline p : pipelines) if (p.isRecording()) return true;
        return false;
    }

    // MARK: settings and state

    private void reloadSettings() {
        Settings fresh = Settings.load(this);
        boolean reopen = settings.pipelineDiffers(fresh);
        settings = fresh;
        for (CameraPipeline p : pipelines) p.apply(fresh);
        if (!reopen) return;
        // New camera or quality from the next clip (spec «Настройки с Mac»).
        reopenWhenIdle = true;
        reopenIfIdle();
    }

    private void reopenIfIdle() {
        if (!reopenWhenIdle || anyRecording()) return;
        reopenWhenIdle = false;
        closeCameras();
        openCameras();
    }

    /** The state of the whole camera from the pipelines and the service's own checks. */
    private String computeState() {
        if (batteryLow) return "battery_low";
        if (noPermission) return "no_permission";
        if (pipelines.isEmpty()) return "no_camera";
        StringBuilder rec = new StringBuilder();
        boolean starting = false, watching = false;
        for (CameraPipeline p : pipelines) {
            if (p.isRecording()) rec.append(rec.length() > 0 ? "," : "").append(p.front ? "front" : "rear");
            if ("starting".equals(p.state)) starting = true;
            if ("watching".equals(p.state) || "recording".equals(p.state)) watching = true;
        }
        active = rec.toString();
        if (rec.length() > 0) return "recording";
        if (lowSpace && watching) return "low_space";
        if (watching) return "watching";
        return starting ? "starting" : "no_camera";
    }

    @Override
    public void changed() {
        if (!running) return;
        String s = computeState();
        if (!s.equals(state)) {
            state = s;
            Log.i(TAG, "state " + s);
            Notifications.updateCamera(this, s);
        }
        reopenIfIdle();
    }

    private int analysedFrames, encodedFrames, motionFrames;
    private double maxFraction;

    @Override
    public void counted(boolean analysed, boolean motion, double fraction) {
        if (!analysed) {
            encodedFrames++;
            return;
        }
        analysedFrames++;
        if (motion) motionFrames++;
        maxFraction = Math.max(maxFraction, fraction);
    }

    /** One log line a minute: shows the cameras keep running with the screen off and in Doze. */
    private final Runnable heartbeat = new Runnable() {
        @Override
        public void run() {
            Log.i(TAG, String.format(Locale.US,
                    "alive: %s, %d camera(s), analysed %d (motion in %d, max %.2f%% changed), encoded %d in the last minute",
                    state, pipelines.size(), analysedFrames, motionFrames, 100 * maxFraction, encodedFrames));
            analysedFrames = encodedFrames = motionFrames = 0;
            maxFraction = 0;
            h.postDelayed(this, 60_000);
        }
    };

    private final Runnable spaceCheck = new Runnable() {
        @Override
        public void run() {
            checkSpace();
            h.postDelayed(this, SPACE_CHECK_MS);
        }
    };

    private void checkSpace() {
        boolean low = ClipStore.freeBytes() < ClipStore.MIN_FREE;
        if (low == lowSpace) return;
        lowSpace = low;
        changed();
    }

    private final BroadcastReceiver battery = new BroadcastReceiver() {
        @Override
        public void onReceive(Context c, Intent i) {
            int level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            boolean plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0;
            int pct = level < 0 ? -1 : level * 100 / Math.max(1, scale);
            batteryPercent = pct;
            charging = plugged;
            if (!batteryLow && pct >= 0 && pct <= 10 && !plugged) {
                batteryLow = true;
                closeCameras();
                changed();
            } else if (batteryLow && plugged) {
                batteryLow = false;
                openCameras();
            }
        }
    };

    private final SensorEventListener gravity = new SensorEventListener() {
        @Override
        public void onSensorChanged(SensorEvent e) {
            // Same rule as OrientationEventListener: how far the device is turned clockwise.
            float x = -e.values[0], y = -e.values[1], z = -e.values[2];
            if (4 * (x * x + y * y) < z * z) return; // lying flat: keep the last value
            int angle = 90 - Math.round((float) Math.toDegrees(Math.atan2(-y, x)));
            angle = ((angle % 360) + 360) % 360;
            deviceRotation = ((angle + 45) / 90 * 90) % 360;
        }

        @Override
        public void onAccuracyChanged(Sensor s, int a) {
        }
    };

    // MARK: Host

    @Override
    public Handler handler() {
        return h;
    }

    @Override
    public CameraManager cameras() {
        return cameraManager;
    }

    @Override
    public ClipStore store() {
        return store;
    }

    @Override
    public Settings settings() {
        return settings;
    }

    @Override
    public boolean lowSpace() {
        return lowSpace;
    }

    @Override
    public int deviceRotation() {
        return deviceRotation;
    }

    @Override
    public long simulateUntilMonoUs() {
        return simulateUntilMonoUs;
    }
}

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
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Locale;
import java.util.Set;

/**
 * The camera service (design D3, D10): the notification, the wake lock, battery and space checks, and one
 * {@link CameraPipeline} per camera in use — the rear or the front one, or both where the device can stream
 * from both at once. Everything runs on one handler thread.
 */
public final class MotionService extends Service implements CameraPipeline.Host, LiveHub.Listener {
    static final String TAG = ClipStore.TAG;
    static final String ACTION_START = "com.universalkm.motion.START";
    static final String ACTION_STOP = "com.universalkm.motion.STOP";

    private static final long S = 1_000_000L;
    private static final long RETRY_MS = 10_000;
    private static final long SPACE_CHECK_MS = 30_000;
    /** The live picture ends when no Mac watches it for this long (design D11). */
    private static final long LIVE_IDLE_MS = 20_000;

    // Read by StatusProvider and MainActivity.
    static volatile boolean running;
    static volatile String state = "off";
    static volatile int batteryPercent = -1;
    static volatile boolean charging;
    /** Cameras recording now ("rear", "front"), for the state line. */
    static volatile String active = "";
    /** The Mac asked for the live picture; ControlActivity keeps the service for it when recording is off. */
    static volatile boolean liveRequested;
    /** Cameras open for the live picture now ("rear", "front"), for the Mac. */
    static volatile String liveOpen = "";

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
    /** Cameras the Mac wants to watch: false = rear, true = front. Handler thread only. */
    private final Set<Boolean> liveWanted = new HashSet<>();
    private LiveHub hub;
    private final Handler main = new Handler(Looper.getMainLooper());

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
            startForeground(Notifications.CAMERA_ID, Notifications.camera(this, running ? state : "starting",
                    hub != null && hub.any()),
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
        final String live = intent == null ? null : intent.getStringExtra("live");
        if (!running) start();
        h.post(() -> {
            if (live != null) setLive(live);
            reloadSettings();
        });
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
        hub = new LiveHub(h, this);
        hub.start();
        h.post(() -> {
            store.recoverPending();
            checkSpace();
        });
        h.postDelayed(spaceCheck, SPACE_CHECK_MS);
        h.postDelayed(heartbeat, 60_000);
    }

    private void stopEverything() {
        if (running) shutdown();
        state = "off";
        active = "";
        liveRequested = false;
        liveOpen = "";
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void shutdown() {
        running = false;
        if (hub != null) hub.stop();
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
        liveRequested = false;
        liveOpen = "";
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

    /**
     * Opens the cameras that are needed now and closes the others (design D10, D11): the recording camera(s)
     * when it is on, plus the ones the Mac watches live. Two cameras only where the device can stream from both
     * at once; otherwise recording wins and the live picture shows the camera that records. A camera that is
     * recording a clip is changed only after the clip (spec «Настройки с Mac»).
     */
    private void configure() {
        if (!running) return;
        if (batteryLow) {
            closeCameras();
            changed();
            return;
        }
        noPermission = checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED;
        if (noPermission) {
            closeCameras();
            changed();
            h.removeCallbacks(retryConfigure);
            h.postDelayed(retryConfigure, RETRY_MS);
            return;
        }
        Map<Boolean, String> want = new HashMap<>();
        Set<Boolean> rec = new HashSet<>();
        int quality = settings.quality;
        try {
            String[] pair = concurrentPair(cameraManager);
            if (settings.on) {
                if ("both".equals(settings.cam) && pair != null) {
                    rec.add(false);
                    rec.add(true);
                } else {
                    if ("both".equals(settings.cam)) {
                        Log.w(TAG, "both cameras asked, but this device cannot stream from both at once: rear only");
                    }
                    rec.add("front".equals(settings.cam));
                }
            }
            Set<Boolean> all = new HashSet<>(rec);
            all.addAll(liveWanted);
            if (all.size() == 2 && pair == null) {
                all = rec.isEmpty() ? new HashSet<>(java.util.Collections.singleton(false)) : rec;
            }
            if (all.size() == 2) {
                // Two cameras at once: Android guarantees streams up to 720p for each (design D10).
                quality = 720;
                want.put(false, pair[0]);
                want.put(true, pair[1]);
            } else {
                for (Boolean front : all) {
                    String id = firstCamera(cameraManager, front);
                    if (id == null) throw new CameraAccessException(CameraAccessException.CAMERA_ERROR, "no camera");
                    want.put(front, id);
                }
            }
        } catch (CameraAccessException | RuntimeException e) {
            Log.w(TAG, "cameras", e);
            closeCameras();
            changed();
            h.removeCallbacks(retryConfigure);
            h.postDelayed(retryConfigure, RETRY_MS);
            return;
        }
        // Recording on or off for the cameras that stay; an open clip of a camera that stops recording ends now.
        for (CameraPipeline p : pipelines) p.setRecord(rec.contains(p.front));
        List<CameraPipeline> gone = new ArrayList<>();
        for (CameraPipeline p : pipelines) {
            String id = want.get(p.front);
            if (id == null || !id.equals(p.cameraId) || p.quality != quality) gone.add(p);
        }
        for (CameraPipeline p : gone) {
            if (p.isRecording()) {
                reopenWhenIdle = true;
                changed();
                return;
            }
        }
        reopenWhenIdle = false;
        for (CameraPipeline p : gone) {
            p.close();
            pipelines.remove(p);
        }
        for (Map.Entry<Boolean, String> e : want.entrySet()) {
            boolean have = false;
            for (CameraPipeline p : pipelines) if (p.front == e.getKey()) have = true;
            if (have) continue;
            CameraPipeline p = new CameraPipeline(this, e.getValue(), e.getKey(), quality);
            p.setRecord(rec.contains(e.getKey()));
            pipelines.add(p);
        }
        openNext();
        for (CameraPipeline p : pipelines) p.label = rec.size() > 1 ? (p.front ? "front" : "rear") : null;
        changed();
    }

    private final Runnable retryConfigure = this::configure;

    /**
     * One camera at a time: on the S10e a second camera opened while the first one sets up its session made
     * that session fail. The next opens once the previous one streams or has failed.
     */
    private void openNext() {
        for (CameraPipeline p : pipelines) if (p.started() && "starting".equals(p.state)) return;
        for (CameraPipeline p : pipelines) {
            if (!p.started()) {
                p.open();
                return;
            }
        }
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
        settings = Settings.load(this);
        for (CameraPipeline p : pipelines) p.apply(settings);
        configure();
        stopIfUnused();
    }

    private void reopenIfIdle() {
        if (!reopenWhenIdle || anyRecording()) return;
        configure();
    }

    // MARK: live picture (design D11)

    /** "back", "front", "both" or "none" from the Mac. */
    private void setLive(String which) {
        liveWanted.clear();
        if ("back".equals(which) || "both".equals(which)) liveWanted.add(false);
        if ("front".equals(which) || "both".equals(which)) liveWanted.add(true);
        liveRequested = !liveWanted.isEmpty();
        Log.i(TAG, "live picture: " + which);
        h.removeCallbacks(liveIdle);
        if (liveRequested && !hub.any()) h.postDelayed(liveIdle, LIVE_IDLE_MS);
    }

    /** No Mac watches any more (it closed the window, slept or lost the connection). */
    private final Runnable liveIdle = () -> {
        if (hub.any() || liveWanted.isEmpty()) return;
        Log.i(TAG, "live picture: nobody watches, ending it");
        liveWanted.clear();
        liveRequested = false;
        configure();
        stopIfUnused();
    };

    @Override
    public void clientsChanged() {
        if (!running) return;
        h.removeCallbacks(liveIdle);
        if (!hub.any() && liveRequested) h.postDelayed(liveIdle, LIVE_IDLE_MS);
        Notifications.updateCamera(this, state, hub.any());
    }

    /** Recording off and nobody watching: the service and its notification go away. */
    private void stopIfUnused() {
        if (settings.on || !liveWanted.isEmpty()) return;
        main.post(() -> {
            if (running && !Settings.load(this).on && !liveRequested) stopEverything();
        });
    }

    /** The state of the whole camera from the pipelines and the service's own checks. */
    private String computeState() {
        StringBuilder live = new StringBuilder();
        for (CameraPipeline p : pipelines) {
            if (!liveWanted.contains(p.front)) continue;
            if ("watching".equals(p.state) || "recording".equals(p.state)) {
                live.append(live.length() > 0 ? "," : "").append(p.front ? "front" : "rear");
            }
        }
        liveOpen = live.toString();
        if (!settings.on) {
            active = "";
            return "off";
        }
        if (batteryLow) return "battery_low";
        if (noPermission) return "no_permission";
        boolean any = false;
        for (CameraPipeline p : pipelines) if (p.records()) any = true;
        if (!any) return "no_camera";
        StringBuilder rec = new StringBuilder();
        boolean starting = false, watching = false;
        for (CameraPipeline p : pipelines) {
            if (!p.records()) continue;
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
            Notifications.updateCamera(this, s, hub != null && hub.any());
        }
        reopenIfIdle();
        openNext();
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
                configure();
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
    public LiveHub live() {
        return hub;
    }

    @Override
    public long simulateUntilMonoUs() {
        return simulateUntilMonoUs;
    }
}

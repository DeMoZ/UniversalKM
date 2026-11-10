package com.universalkm.motion;

import android.Manifest;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.graphics.ImageFormat;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.OutputConfiguration;
import android.hardware.camera2.params.SessionConfiguration;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.BatteryManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;
import android.util.Range;
import android.util.Size;
import android.view.Surface;

import com.universalkm.motion.core.ClipPolicy;
import com.universalkm.motion.core.EncodedFrame;
import com.universalkm.motion.core.FragmentedMp4Writer;
import com.universalkm.motion.core.FrameRing;
import com.universalkm.motion.core.MotionDetector;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.Executor;

/**
 * The camera, the motion detector and the recorder (design D3, D4). Everything runs on one handler thread:
 * camera callbacks, analysis frames, encoder output and file writes.
 */
public final class MotionService extends Service {
    static final String TAG = ClipStore.TAG;
    static final String ACTION_START = "com.universalkm.motion.START";
    static final String ACTION_STOP = "com.universalkm.motion.STOP";

    private static final long S = 1_000_000L;
    private static final long PRE_ROLL_US = 3 * S;
    private static final long MAX_CLIP_US = 600 * S;
    private static final long ANALYSIS_INTERVAL_NS = 200_000_000L; // 5 per second
    private static final long RETRY_MS = 10_000;
    private static final long SPACE_CHECK_MS = 30_000;
    /** Auto exposure and focus settle after the camera opens: no motion before that. */
    private static final long WARM_UP_US = 2 * S;

    // Read by StatusProvider and MainActivity.
    static volatile boolean running;
    static volatile String state = "off";
    static volatile int batteryPercent = -1;
    static volatile boolean charging;

    private HandlerThread thread;
    private Handler h;
    private Settings settings;
    private PowerManager.WakeLock wakeLock;
    private ClipStore store;

    private final MotionDetector detector = new MotionDetector();
    private ClipPolicy policy;
    private final FrameRing ring = new FrameRing(PRE_ROLL_US + 2 * S);

    private CameraDevice camera;
    private CameraCaptureSession session;
    private ImageReader reader;
    private MediaCodec encoder;
    private Surface encoderSurface;
    private int generation; // callbacks of a closed pipeline are ignored
    private byte[] sps, pps;
    private int encWidth, encHeight;
    private int sensorOrientation;
    private boolean frontFacing;
    private boolean realtimeClock;
    // Analysis images and encoder frames may come on different clocks: the camera converts timestamps of
    // video encoder outputs to the monotonic clock even when its own source is elapsedRealtime. Each source is
    // checked on its first sample, and everything is kept on the monotonic clock (System.nanoTime).
    private int imageClock;   // 0 unknown, 1 monotonic, 2 realtime
    private int encoderClock;
    private long openedMonoUs;
    private long lastAnalysisNs;
    private byte[] luma;

    private ClipStore.Clip clip;
    private FragmentedMp4Writer writer;
    private boolean restartAfterClip;
    private boolean batteryLow;
    private boolean lowSpace;
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
        policy = new ClipPolicy(PRE_ROLL_US, settings.stopSec * S, MAX_CLIP_US);
        detector.setSensitivity(settings.sens);
        store = new ClipStore(this);
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
            openPipeline();
        });
        h.postDelayed(spaceCheck, SPACE_CHECK_MS);
        h.postDelayed(heartbeat, 60_000);
    }

    private void stopEverything() {
        if (running) shutdown();
        state = "off";
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void shutdown() {
        running = false;
        final Handler handler = h;
        if (handler != null) {
            // Close the clip and the camera on their own thread, then let the thread go.
            final Object done = new Object();
            final boolean[] finished = {false};
            handler.post(() -> {
                closePipeline();
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
            handler.removeCallbacksAndMessages(null);
        }
        try {
            unregisterReceiver(battery);
        } catch (RuntimeException ignored) {
        }
        if (sensors != null) sensors.unregisterListener(gravity);
        if (thread != null) thread.quitSafely();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        state = "off";
    }

    // MARK: settings and state

    private void reloadSettings() {
        Settings fresh = Settings.load(this);
        boolean reopen = settings.pipelineDiffers(fresh);
        settings = fresh;
        detector.setSensitivity(fresh.sens);
        policy.setStopDelayUs(fresh.stopSec * S);
        if (!reopen) return;
        if (clip != null) {
            restartAfterClip = true; // new camera or quality from the next clip (spec «Настройки с Mac»)
        } else {
            closePipeline();
            openPipeline();
        }
    }

    private void setState(String s) {
        if (s.equals(state)) return;
        state = s;
        Log.i(TAG, "state " + s);
        if (running) Notifications.updateCamera(this, s);
    }

    private int analysedFrames, encodedFrames, motionFrames;
    private double maxFraction;

    /** One log line a minute: shows the camera keeps running with the screen off and in Doze. */
    private final Runnable heartbeat = new Runnable() {
        @Override
        public void run() {
            Log.i(TAG, String.format(java.util.Locale.US,
                    "alive: %s, analysed %d (motion in %d, max %.2f%% changed), encoded %d in the last minute, ring %d frames",
                    state, analysedFrames, motionFrames, 100 * maxFraction, encodedFrames, ring.size()));
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
        lowSpace = ClipStore.freeBytes() < ClipStore.MIN_FREE;
        if (lowSpace && "watching".equals(state)) setState("low_space");
        if (!lowSpace && "low_space".equals(state)) setState("watching");
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
                closePipeline();
                setState("battery_low");
            } else if (batteryLow && plugged) {
                batteryLow = false;
                openPipeline();
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

    // MARK: camera and encoder

    private void openPipeline() {
        if (!running || camera != null || encoder != null) return;
        if (batteryLow) {
            setState("battery_low");
            return;
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            setState("no_permission");
            h.postDelayed(this::openPipeline, RETRY_MS);
            return;
        }
        final int gen = ++generation;
        try {
            CameraManager cm = getSystemService(CameraManager.class);
            String id = pickCamera(cm, "front".equals(settings.cam));
            if (id == null) throw new CameraAccessException(CameraAccessException.CAMERA_ERROR, "no camera");
            CameraCharacteristics ch = cm.getCameraCharacteristics(id);
            Integer so = ch.get(CameraCharacteristics.SENSOR_ORIENTATION);
            sensorOrientation = so == null ? 0 : so;
            Integer facing = ch.get(CameraCharacteristics.LENS_FACING);
            frontFacing = facing != null && facing == CameraCharacteristics.LENS_FACING_FRONT;
            Integer src = ch.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE);
            realtimeClock = src != null && src == CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME;
            StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            Size enc = chooseEncoderSize(map.getOutputSizes(MediaCodec.class), settings.quality);
            Size an = chooseAnalysisSize(map.getOutputSizes(ImageFormat.YUV_420_888), enc);
            Range<Integer> fps = chooseFps(ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES));

            encWidth = enc.getWidth();
            encHeight = enc.getHeight();
            MediaFormat f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, encWidth, encHeight);
            f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            f.setInteger(MediaFormat.KEY_BIT_RATE, settings.quality >= 1080 ? 8_000_000 : 4_000_000);
            f.setInteger(MediaFormat.KEY_FRAME_RATE, 30);
            f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
            f.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0);
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            encoder.setCallback(new EncoderCallback(gen), h);
            encoder.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            encoderSurface = encoder.createInputSurface();
            encoder.start();

            reader = ImageReader.newInstance(an.getWidth(), an.getHeight(), ImageFormat.YUV_420_888, 3);
            reader.setOnImageAvailableListener(r -> {
                if (gen == generation) onAnalysisImage(r);
            }, h);
            Log.i(TAG, "camera " + id + (frontFacing ? " front" : " back") + ", encoder " + enc + ", analysis " + an
                    + ", fps " + fps + ", sensor " + sensorOrientation + "°, clock " + (realtimeClock ? "realtime" : "monotonic"));
            setState("starting");
            cm.openCamera(id, new CameraCallback(gen, fps), h);
        } catch (CameraAccessException | IOException | RuntimeException e) {
            Log.w(TAG, "open camera", e);
            failPipeline();
        }
    }

    private void failPipeline() {
        closePipeline();
        if (!running || batteryLow) return;
        setState("no_camera");
        h.postDelayed(this::openPipeline, RETRY_MS);
    }

    private void closePipeline() {
        generation++;
        finishClip();
        if (session != null) {
            try {
                session.close();
            } catch (RuntimeException ignored) {
            }
            session = null;
        }
        if (camera != null) {
            camera.close();
            camera = null;
        }
        if (encoder != null) {
            try {
                encoder.stop();
            } catch (RuntimeException ignored) {
            }
            encoder.release();
            encoder = null;
        }
        if (encoderSurface != null) {
            encoderSurface.release();
            encoderSurface = null;
        }
        if (reader != null) {
            reader.close();
            reader = null;
        }
        ring.clear();
        if (policy != null) policy.reset();
        detector.reset();
        sps = pps = null;
        imageClock = encoderClock = 0;
    }

    /** 1 = the timestamp is close to the monotonic clock, 2 = to elapsedRealtime. */
    private static int clockOf(long tsUs) {
        long mono = System.nanoTime() / 1000, real = SystemClock.elapsedRealtimeNanos() / 1000;
        return Math.abs(tsUs - real) < Math.abs(tsUs - mono) ? 2 : 1;
    }

    private static long toMonoUs(long tsUs, int clock) {
        if (clock != 2) return tsUs;
        return tsUs - (SystemClock.elapsedRealtimeNanos() - System.nanoTime()) / 1000;
    }

    private final class CameraCallback extends CameraDevice.StateCallback {
        private final int gen;
        private final Range<Integer> fps;

        CameraCallback(int gen, Range<Integer> fps) {
            this.gen = gen;
            this.fps = fps;
        }

        @Override
        public void onOpened(CameraDevice cam) {
            if (gen != generation) {
                cam.close();
                return;
            }
            camera = cam;
            try {
                List<OutputConfiguration> outs = Arrays.asList(
                        new OutputConfiguration(encoderSurface), new OutputConfiguration(reader.getSurface()));
                Executor ex = h::post;
                cam.createCaptureSession(new SessionConfiguration(SessionConfiguration.SESSION_REGULAR, outs, ex,
                        new CameraCaptureSession.StateCallback() {
                            @Override
                            public void onConfigured(CameraCaptureSession s) {
                                if (gen != generation) {
                                    s.close();
                                    return;
                                }
                                session = s;
                                try {
                                    CaptureRequest.Builder b = cam.createCaptureRequest(CameraDevice.TEMPLATE_RECORD);
                                    b.addTarget(encoderSurface);
                                    b.addTarget(reader.getSurface());
                                    if (fps != null) b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fps);
                                    s.setRepeatingRequest(b.build(), null, h);
                                    openedMonoUs = System.nanoTime() / 1000;
                                    setState(lowSpace ? "low_space" : "watching");
                                } catch (CameraAccessException | RuntimeException e) {
                                    Log.w(TAG, "repeating request", e);
                                    failPipeline();
                                }
                            }

                            @Override
                            public void onConfigureFailed(CameraCaptureSession s) {
                                Log.w(TAG, "session configure failed");
                                if (gen == generation) failPipeline();
                            }
                        }));
            } catch (CameraAccessException | RuntimeException e) {
                Log.w(TAG, "session", e);
                failPipeline();
            }
        }

        @Override
        public void onDisconnected(CameraDevice cam) {
            Log.w(TAG, "camera disconnected (another app or the privacy switch)");
            if (gen == generation) failPipeline();
            else cam.close();
        }

        @Override
        public void onError(CameraDevice cam, int error) {
            Log.w(TAG, "camera error " + error);
            if (gen == generation) failPipeline();
            else cam.close();
        }
    }

    private final class EncoderCallback extends MediaCodec.Callback {
        private final int gen;

        EncoderCallback(int gen) {
            this.gen = gen;
        }

        @Override
        public void onInputBufferAvailable(MediaCodec codec, int index) {
        }

        @Override
        public void onOutputBufferAvailable(MediaCodec codec, int index, MediaCodec.BufferInfo info) {
            if (gen != generation) return;
            ByteBuffer buf;
            try {
                buf = codec.getOutputBuffer(index);
            } catch (RuntimeException e) {
                return;
            }
            byte[] data = new byte[info.size];
            if (buf != null && info.size > 0) {
                buf.position(info.offset);
                buf.get(data, 0, info.size);
            }
            codec.releaseOutputBuffer(index, false);
            if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                takeParameterSets(data);
                return;
            }
            if (info.size == 0) return;
            if (encoderClock == 0) {
                encoderClock = clockOf(info.presentationTimeUs);
                Log.i(TAG, "clocks: images " + (imageClock == 2 ? "realtime" : "monotonic")
                        + ", encoder " + (encoderClock == 2 ? "realtime" : "monotonic"));
            }
            long pts = toMonoUs(info.presentationTimeUs, encoderClock);
            onEncodedFrame(new EncodedFrame(pts, (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0, data));
        }

        @Override
        public void onError(MediaCodec codec, MediaCodec.CodecException e) {
            Log.w(TAG, "encoder", e);
            if (gen == generation) failPipeline();
        }

        @Override
        public void onOutputFormatChanged(MediaCodec codec, MediaFormat format) {
            ByteBuffer a = format.getByteBuffer("csd-0"), b = format.getByteBuffer("csd-1");
            if (a != null && b != null) {
                sps = FragmentedMp4Writer.stripStartCode(bytes(a));
                pps = FragmentedMp4Writer.stripStartCode(bytes(b));
            }
        }
    }

    private static byte[] bytes(ByteBuffer b) {
        ByteBuffer d = b.duplicate();
        byte[] out = new byte[d.remaining()];
        d.get(out);
        return out;
    }

    /** A codec-config buffer holds SPS and PPS with start codes. */
    private void takeParameterSets(byte[] data) {
        for (int[] n : FragmentedMp4Writer.nalUnits(data)) {
            int type = data[n[0]] & 0x1F;
            byte[] nal = Arrays.copyOfRange(data, n[0], n[1]);
            if (type == 7) sps = nal;
            if (type == 8) pps = nal;
        }
    }

    // MARK: analysis

    private void onAnalysisImage(ImageReader r) {
        Image img;
        try {
            img = r.acquireLatestImage();
        } catch (RuntimeException e) {
            return;
        }
        if (img == null) return;
        try {
            long ts = img.getTimestamp();
            if (imageClock == 0) imageClock = clockOf(ts / 1000);
            if (ts - lastAnalysisNs < ANALYSIS_INTERVAL_NS) return;
            lastAnalysisNs = ts;
            Image.Plane p = img.getPlanes()[0];
            ByteBuffer b = p.getBuffer();
            int n = b.remaining();
            if (luma == null || luma.length < n) luma = new byte[n];
            b.get(luma, 0, n);
            analysedFrames++;
            long mono = toMonoUs(ts / 1000, imageClock);
            // While exposure settles, the background restarts from each frame.
            if (mono - openedMonoUs < WARM_UP_US) detector.reset();
            boolean moving = detector.process(luma, img.getWidth(), img.getHeight(), p.getRowStride(), p.getPixelStride());
            if (moving && !policy.isRecording()) {
                Log.i(TAG, String.format(java.util.Locale.US, "motion: %.2f%% of the picture changed", 100 * detector.lastFraction()));
            }
            maxFraction = Math.max(maxFraction, detector.lastFraction());
            if (moving) motionFrames++;
            if (mono < simulateUntilMonoUs) moving = true;
            policy.motion(mono, moving);
        } finally {
            img.close();
        }
    }

    // MARK: clips

    private void onEncodedFrame(EncodedFrame f) {
        encodedFrames++;
        ring.add(f);
        switch (policy.frame(f.ptsUs, f.key)) {
            case START: {
                if (lowSpace || sps == null || pps == null) {
                    policy.reset();
                    break;
                }
                List<EncodedFrame> pre = ring.from(policy.startFromUs());
                if (pre.isEmpty()) {
                    policy.deferStart();
                    break;
                }
                if (!openClip(pre.get(0).ptsUs)) {
                    policy.reset();
                    break;
                }
                policy.started(pre.get(0).ptsUs);
                for (EncodedFrame e : pre) writeFrame(e);
                setState("recording");
                break;
            }
            case WRITE:
                writeFrame(f);
                break;
            case STOP:
                finishClip();
                setState(lowSpace ? "low_space" : "watching");
                if (restartAfterClip) h.post(this::restartPipeline);
                break;
            case ROLL:
                finishClip();
                if (restartAfterClip) {
                    h.post(this::restartPipeline);
                    break;
                }
                if (openClip(f.ptsUs)) writeFrame(f);
                else policy.reset();
                break;
            default:
        }
    }

    private void restartPipeline() {
        restartAfterClip = false;
        closePipeline();
        openPipeline();
    }

    /** Wall-clock time of a monotonic timestamp. */
    private static long wallMillis(long monoUs) {
        return System.currentTimeMillis() - Math.max(0, System.nanoTime() / 1000 - monoUs) / 1000;
    }

    private boolean openClip(long firstPtsUs) {
        long start = wallMillis(firstPtsUs);
        try {
            store.enforceLimit(settings.limitMB * 1024 * 1024, 0);
            clip = store.open(start);
            int rot = frontFacing ? (sensorOrientation - deviceRotation + 360) % 360
                    : (sensorOrientation + deviceRotation) % 360;
            writer = new FragmentedMp4Writer(clip.channel, encWidth, encHeight, sps, pps, rot, start / 1000, true);
            Log.i(TAG, "clip " + clip.name + " rotation " + rot);
            return true;
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "open clip", e);
            if (clip != null) store.finish(clip, false, h);
            clip = null;
            writer = null;
            return false;
        }
    }

    private void writeFrame(EncodedFrame f) {
        if (writer == null) return;
        try {
            writer.write(f.ptsUs, f.key, f.data);
            if (writer.bytes() > settings.limitMB * 1024 * 1024) { // a single clip bigger than the limit
                finishClip();
                policy.reset();
            }
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "write", e);
            finishClip();
            policy.reset();
            checkSpace();
        }
    }

    private void finishClip() {
        if (clip == null) return;
        long n = 0;
        long size = 0;
        try {
            if (writer != null) {
                writer.close();
                n = writer.samples();
                size = writer.bytes();
            }
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "close clip", e);
        }
        store.finish(clip, n > 0, h);
        Log.i(TAG, "clip " + clip.name + " closed: " + n + " frames, " + size + " bytes");
        clip = null;
        writer = null;
        store.enforceLimit(settings.limitMB * 1024 * 1024, 0);
    }

    // MARK: choosing sizes

    private static String pickCamera(CameraManager cm, boolean front) throws CameraAccessException {
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

    static Size chooseEncoderSize(Size[] sizes, int quality) {
        int tw = quality >= 1080 ? 1920 : 1280, th = quality >= 1080 ? 1080 : 720;
        Size best = null;
        for (Size s : sizes) {
            if (s.getWidth() == tw && s.getHeight() == th) return s;
            boolean wide = Math.abs(s.getWidth() * 9 - s.getHeight() * 16) < s.getHeight();
            if (!wide || s.getWidth() > tw) continue;
            if (best == null || s.getWidth() > best.getWidth()) best = s;
        }
        if (best != null) return best;
        for (Size s : sizes) {
            if (s.getWidth() * s.getHeight() > tw * th) continue;
            if (best == null || s.getWidth() * s.getHeight() > best.getWidth() * best.getHeight()) best = s;
        }
        return best != null ? best : sizes[0];
    }

    /** The smallest size of at least 320 wide with the encoder's aspect ratio, so both see the same picture. */
    static Size chooseAnalysisSize(Size[] sizes, Size enc) {
        Size best = null;
        for (Size s : sizes) {
            boolean same = Math.abs(s.getWidth() * enc.getHeight() - s.getHeight() * enc.getWidth()) < enc.getWidth();
            if (!same || s.getWidth() < 320) continue;
            if (best == null || s.getWidth() < best.getWidth()) best = s;
        }
        if (best != null) return best;
        for (Size s : sizes) {
            if (s.getWidth() < 320) continue;
            if (best == null || s.getWidth() * s.getHeight() < best.getWidth() * best.getHeight()) best = s;
        }
        return best != null ? best : sizes[sizes.length - 1];
    }

    /** Up to 30 per second, as low as the camera allows in the dark. */
    static Range<Integer> chooseFps(Range<Integer>[] ranges) {
        if (ranges == null) return null;
        Range<Integer> best = null;
        for (Range<Integer> r : ranges) {
            if (r.getUpper() != 30) continue;
            if (best == null || r.getLower() < best.getLower()) best = r;
        }
        return best;
    }
}

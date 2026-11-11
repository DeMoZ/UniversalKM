package com.universalkm.motion;

import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.OutputConfiguration;
import android.hardware.camera2.params.SessionConfiguration;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.graphics.ImageFormat;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Handler;
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
import java.util.Locale;
import java.util.concurrent.Executor;

/**
 * One camera (design D4, D10): its capture session with an analysis reader and an encoder, its own motion
 * detector, clip policy, pre-roll ring and open clip. Everything runs on the service's handler thread. With
 * "both" cameras the service runs two of these, each recording its own clips.
 */
final class CameraPipeline {
    static final String TAG = ClipStore.TAG;
    private static final long S = 1_000_000L;
    static final long PRE_ROLL_US = 3 * S;
    private static final long MAX_CLIP_US = 600 * S;
    private static final long ANALYSIS_INTERVAL_NS = 200_000_000L; // 5 per second
    private static final long RETRY_MS = 10_000;
    /**
     * The first retry is quick: another app in front (the phone's own camera app left open behind the lock screen)
     * often takes the camera only for a moment, when our command activity closes.
     */
    private static final long FIRST_RETRY_MS = 2_000;
    private int failures;
    /** Auto exposure and focus settle after the camera opens: no motion before that. */
    private static final long WARM_UP_US = 2 * S;

    /** What the pipeline needs from the service. */
    interface Host {
        Handler handler();
        CameraManager cameras();
        ClipStore store();
        Settings settings();
        boolean lowSpace();
        int deviceRotation();
        long simulateUntilMonoUs();
        /** The pipeline's state changed (also when a clip opens or closes). */
        void changed();
        void counted(boolean analysed, boolean motion, double fraction);
        /** Where encoded frames go for the live picture on the Mac (design D11). */
        LiveHub live();
    }

    final String cameraId;
    final boolean front;
    /** "rear" / "front" in the clip names when both cameras record; null with one. Set by the service. */
    volatile String label;
    final int quality;
    /** false: the camera is open only for the live picture and records nothing (design D11). */
    private boolean record = true;
    private final Host host;
    private final Handler h;

    /** starting, watching, recording, no_camera */
    volatile String state = "starting";
    private boolean closed;

    private final MotionDetector detector = new MotionDetector();
    private final ClipPolicy policy;
    private final FrameRing ring = new FrameRing(PRE_ROLL_US + 2 * S);

    private CameraDevice camera;
    private CameraCaptureSession session;
    private ImageReader reader;
    private MediaCodec encoder;
    private Surface encoderSurface;
    private int generation; // callbacks of a closed camera are ignored
    private byte[] sps, pps;
    private int encWidth, encHeight;
    private int sensorOrientation;
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

    CameraPipeline(Host host, String cameraId, boolean front, int quality) {
        this.host = host;
        this.h = host.handler();
        this.cameraId = cameraId;
        this.front = front;
        this.quality = quality;
        Settings s = host.settings();
        policy = new ClipPolicy(PRE_ROLL_US, s.stopSec * S, MAX_CLIP_US);
        detector.setSensitivity(s.sens);
    }

    boolean isRecording() {
        return clip != null;
    }

    boolean records() {
        return record;
    }

    /** Off: an open clip ends at once (spec «Включение и выключение»); the camera stays for the live picture. */
    void setRecord(boolean on) {
        if (record == on) return;
        record = on;
        if (!on) {
            finishClip();
            policy.reset();
            if ("recording".equals(state)) setState("watching");
        }
    }

    /** Sensitivity and stop delay take effect at once. */
    void apply(Settings s) {
        detector.setSensitivity(s.sens);
        policy.setStopDelayUs(s.stopSec * S);
    }

    // MARK: open and close

    /** open() was called: the service opens cameras one after another (design D10). */
    boolean started() {
        return started;
    }

    private boolean started;

    void open() {
        started = true;
        if (closed || camera != null || encoder != null) return;
        final int gen = ++generation;
        try {
            CameraManager cm = host.cameras();
            CameraCharacteristics ch = cm.getCameraCharacteristics(cameraId);
            Integer so = ch.get(CameraCharacteristics.SENSOR_ORIENTATION);
            sensorOrientation = so == null ? 0 : so;
            StreamConfigurationMap map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            Size enc = chooseEncoderSize(map.getOutputSizes(MediaCodec.class), quality);
            Size an = chooseAnalysisSize(map.getOutputSizes(ImageFormat.YUV_420_888), enc);
            Range<Integer> fps = chooseFps(ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES));

            encWidth = enc.getWidth();
            encHeight = enc.getHeight();
            MediaFormat f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, encWidth, encHeight);
            f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            f.setInteger(MediaFormat.KEY_BIT_RATE, quality >= 1080 ? 8_000_000 : 4_000_000);
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
            Log.i(TAG, "camera " + cameraId + (front ? " front" : " back") + ", encoder " + enc + ", analysis " + an
                    + ", fps " + fps + ", sensor " + sensorOrientation + "°");
            setState("starting");
            cm.openCamera(cameraId, new CameraCallback(gen, fps), h);
        } catch (CameraAccessException | IOException | RuntimeException e) {
            Log.w(TAG, "open camera " + cameraId, e);
            fail();
        }
    }

    /** Closes the clip and the camera; a closed pipeline does not reopen. */
    void close() {
        closed = true;
        release();
    }

    private void fail() {
        release();
        if (closed) return;
        setState("no_camera");
        h.postDelayed(this::open, failures++ == 0 ? FIRST_RETRY_MS : RETRY_MS);
    }

    private void release() {
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
        policy.reset();
        detector.reset();
        sps = pps = null;
        imageClock = encoderClock = 0;
    }

    private void setState(String s) {
        if (s.equals(state)) return;
        state = s;
        Log.i(TAG, "camera " + cameraId + ": " + s);
        host.changed();
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
                                    failures = 0;
                                    setState("watching");
                                } catch (CameraAccessException | RuntimeException e) {
                                    Log.w(TAG, "repeating request", e);
                                    fail();
                                }
                            }

                            @Override
                            public void onConfigureFailed(CameraCaptureSession s) {
                                Log.w(TAG, "session configure failed, camera " + cameraId);
                                if (gen == generation) fail();
                            }
                        }));
            } catch (CameraAccessException | RuntimeException e) {
                Log.w(TAG, "session", e);
                fail();
            }
        }

        @Override
        public void onDisconnected(CameraDevice cam) {
            Log.w(TAG, "camera " + cameraId + " disconnected (another app or the privacy switch)");
            if (gen == generation) fail();
            else cam.close();
        }

        @Override
        public void onError(CameraDevice cam, int error) {
            Log.w(TAG, "camera " + cameraId + " error " + error);
            if (gen == generation) fail();
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
                Log.i(TAG, "camera " + cameraId + " clocks: images " + (imageClock == 2 ? "realtime" : "monotonic")
                        + ", encoder " + (encoderClock == 2 ? "realtime" : "monotonic"));
            }
            host.counted(false, false, 0);
            long pts = toMonoUs(info.presentationTimeUs, encoderClock);
            onEncodedFrame(new EncodedFrame(pts, (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0, data));
        }

        @Override
        public void onError(MediaCodec codec, MediaCodec.CodecException e) {
            Log.w(TAG, "encoder", e);
            if (gen == generation) fail();
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

    /** 1 = the timestamp is close to the monotonic clock, 2 = to elapsedRealtime. */
    private static int clockOf(long tsUs) {
        long mono = System.nanoTime() / 1000, real = SystemClock.elapsedRealtimeNanos() / 1000;
        return Math.abs(tsUs - real) < Math.abs(tsUs - mono) ? 2 : 1;
    }

    private static long toMonoUs(long tsUs, int clock) {
        if (clock != 2) return tsUs;
        return tsUs - (SystemClock.elapsedRealtimeNanos() - System.nanoTime()) / 1000;
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
            long mono = toMonoUs(ts / 1000, imageClock);
            // While exposure settles, the background restarts from each frame.
            if (mono - openedMonoUs < WARM_UP_US) detector.reset();
            boolean moving = detector.process(luma, img.getWidth(), img.getHeight(), p.getRowStride(), p.getPixelStride());
            host.counted(true, moving, detector.lastFraction());
            if (moving && !policy.isRecording()) {
                Log.i(TAG, String.format(Locale.US, "camera %s motion: %.2f%% of the picture changed",
                        cameraId, 100 * detector.lastFraction()));
            }
            if (mono < host.simulateUntilMonoUs()) moving = true;
            if (!record) moving = false;
            policy.motion(mono, moving);
        } finally {
            img.close();
        }
    }

    // MARK: clips

    private void onEncodedFrame(EncodedFrame f) {
        host.live().frame(front, f, sps, pps, encWidth, encHeight, rotation());
        ring.add(f);
        switch (policy.frame(f.ptsUs, f.key)) {
            case START: {
                if (host.lowSpace() || sps == null || pps == null) {
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
                setState("watching");
                break;
            case ROLL:
                finishClip();
                if (openClip(f.ptsUs)) {
                    writeFrame(f);
                } else {
                    policy.reset();
                    setState("watching");
                }
                break;
            default:
        }
    }

    /** Wall-clock time of a monotonic timestamp. */
    private static long wallMillis(long monoUs) {
        return System.currentTimeMillis() - Math.max(0, System.nanoTime() / 1000 - monoUs) / 1000;
    }

    private long limitBytes() {
        return host.settings().limitMB * 1024 * 1024;
    }

    /** Clockwise turn that shows the picture upright, for the clip and the live picture. */
    private int rotation() {
        int dr = host.deviceRotation();
        return front ? (sensorOrientation - dr + 360) % 360 : (sensorOrientation + dr) % 360;
    }

    private boolean openClip(long firstPtsUs) {
        long start = wallMillis(firstPtsUs);
        ClipStore store = host.store();
        try {
            store.enforceLimit(limitBytes(), 0);
            clip = store.open(start, label);
            int rot = rotation();
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
            if (writer.bytes() > limitBytes()) { // a single clip bigger than the limit
                finishClip();
                policy.reset();
                setState("watching");
            }
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "write", e);
            finishClip();
            policy.reset();
            setState("watching");
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
        ClipStore store = host.store();
        store.finish(clip, n > 0, h);
        Log.i(TAG, "clip " + clip.name + " closed: " + n + " frames, " + size + " bytes");
        clip = null;
        writer = null;
        store.enforceLimit(limitBytes(), 0);
        host.changed();
    }

    // MARK: choosing sizes

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

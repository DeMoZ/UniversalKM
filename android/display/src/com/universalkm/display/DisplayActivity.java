package com.universalkm.display;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Rect;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import com.universalkm.display.core.Protocol;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

/**
 * The receiver of the Mac's second display (openspec/changes/add-android-second-display, design D4, D5): listens
 * on a local socket the Mac reaches through {@code adb forward}, decodes its H.264 stream onto a full-screen
 * surface and sends the touches back. Keeps the screen on, hides the system bars, closes 60 s after the Mac is lost.
 */
public final class DisplayActivity extends Activity implements SurfaceHolder.Callback {
    private static final long LOST_TIMEOUT_MS = 60_000;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private SurfaceView surfaceView;
    private TextView waiting;

    /** Held by the session thread while a Mac is connected. */
    private volatile Session session;
    private volatile Surface surface;
    private LocalServerSocket server;
    private Thread acceptor;
    private volatile boolean closing;
    private final Runnable giveUp = this::finish;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().addCallback(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(-1, -1));
        waiting = new TextView(this);
        waiting.setText(R.string.waiting);
        waiting.setTextColor(Color.LTGRAY);
        waiting.setTextSize(20);
        root.addView(waiting, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        setContentView(root);
        hideSystemBars();
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    private void hideSystemBars() {
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    // MARK: Surface

    @Override public void surfaceCreated(SurfaceHolder holder) {
        surface = holder.getSurface();
        startListening();
        Session s = session;
        if (s != null) s.resume(); // the surface came back after a rotation: decode into the new one
    }

    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}

    @Override public void surfaceDestroyed(SurfaceHolder holder) {
        surface = null;
        Session s = session;
        if (s != null) s.pause(); // a rotation may recreate the surface: keep the connection
    }

    @Override public void onConfigurationChanged(android.content.res.Configuration config) {
        super.onConfigurationChanged(config);
        Session s = session;
        if (s != null) {
            int[] size = screenSize();
            s.send(Protocol.rotated(size[0], size[1]));
        }
    }

    /** The screen in pixels in the current orientation. */
    private int[] screenSize() {
        Rect b = getWindowManager().getMaximumWindowMetrics().getBounds();
        return new int[] {b.width(), b.height()};
    }

    @Override protected void onDestroy() {
        closing = true;
        ui.removeCallbacks(giveUp);
        Session s = session;
        if (s != null) s.close();
        try {
            if (server != null) server.close();
        } catch (IOException ignored) {
        }
        super.onDestroy();
    }

    // MARK: Listening

    private synchronized void startListening() {
        if (acceptor != null) return;
        acceptor = new Thread(() -> {
            try {
                server = new LocalServerSocket(Protocol.SOCKET);
            } catch (IOException e) {
                ui.post(this::finish);
                return;
            }
            while (!closing) {
                ui.post(() -> {
                    waiting.setText(hasHardwareH264() ? R.string.waiting : R.string.no_decoder);
                    waiting.setVisibility(View.VISIBLE);
                    ui.removeCallbacks(giveUp);
                    ui.postDelayed(giveUp, LOST_TIMEOUT_MS);
                });
                LocalSocket client;
                try {
                    client = server.accept();
                } catch (IOException e) {
                    return;
                }
                ui.post(() -> ui.removeCallbacks(giveUp));
                Session s = new Session(client);
                session = s;
                s.run(); // returns when the Mac is gone
                session = null;
            }
        }, "ukm-display-accept");
        acceptor.start();
    }

    private static boolean hasHardwareH264() {
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (info.isEncoder() || !info.isHardwareAccelerated()) continue;
            for (String type : info.getSupportedTypes()) if (type.equalsIgnoreCase("video/avc")) return true;
        }
        return false;
    }

    // MARK: Touches

    @Override public boolean onTouchEvent(MotionEvent e) {
        Session s = session;
        if (s == null) return super.onTouchEvent(e);
        int action;
        int fingers = e.getPointerCount();
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: action = Protocol.TOUCH_DOWN; break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL: action = Protocol.TOUCH_UP; break;
            case MotionEvent.ACTION_POINTER_UP: action = Protocol.TOUCH_MOVE; fingers -= 1; break;
            default: action = Protocol.TOUCH_MOVE; break;
        }
        // The centre of the fingers that stay down, over the picture.
        float x = 0, y = 0;
        int n = 0;
        for (int i = 0; i < e.getPointerCount(); i++) {
            if (e.getActionMasked() == MotionEvent.ACTION_POINTER_UP && i == e.getActionIndex()) continue;
            x += e.getX(i);
            y += e.getY(i);
            n++;
        }
        if (n == 0) return true;
        int w = Math.max(surfaceView.getWidth(), 1), h = Math.max(surfaceView.getHeight(), 1);
        s.send(Protocol.touch(action, fingers, Math.round(x / n / w * 65535), Math.round(y / n / h * 65535),
                e.getEventTime()));
        return true;
    }

    // MARK: One Mac

    /** One connection: reads the Mac's messages, decodes, reports. */
    private final class Session {
        private final LocalSocket socket;
        private final Object writeLock = new Object();
        private OutputStream out;
        private MediaCodec codec;
        private Thread output;
        private final Map<Long, Long> queuedAt = new HashMap<>();
        private volatile boolean done;
        private boolean needKey = true;
        private final Object codecLock = new Object();
        private int lastWidth, lastHeight;
        private byte[] lastSets;

        Session(LocalSocket socket) {
            this.socket = socket;
        }

        void send(byte[] message) {
            synchronized (writeLock) {
                try {
                    if (out != null) out.write(message);
                } catch (IOException e) {
                    close();
                }
            }
        }

        void close() {
            done = true;
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }

        void run() {
            try {
                out = socket.getOutputStream();
                InputStream in = socket.getInputStream();
                int[] size = screenSize();
                send(Protocol.hello(size[0], size[1], hasHardwareH264()));
                Protocol.Message m;
                while (!done && (m = Protocol.read(in)) != null) handle(m);
            } catch (IOException | RuntimeException ignored) {
                // The Mac left or sent garbage: wait for the next one.
            } finally {
                done = true;
                stopCodec();
                try {
                    socket.close();
                } catch (IOException ignored) {
                }
            }
        }

        private void handle(Protocol.Message m) throws IOException {
            if (m.type == Protocol.CONFIG) {
                startCodec(Protocol.configWidth(m.body), Protocol.configHeight(m.body),
                        Protocol.configParameterSets(m.body));
            } else if (m.type == Protocol.FRAME) {
                decode(m.body);
            }
        }

        /** The surface is gone: stop the decoder, keep the connection and what is needed to start it again. */
        void pause() {
            stopCodec();
        }

        /** The surface is back: start the decoder again and ask the Mac for a key frame. */
        void resume() {
            synchronized (codecLock) {
                if (lastSets == null || codec != null || done) return;
                try {
                    startCodec(lastWidth, lastHeight, lastSets);
                    send(Protocol.keyFrameRequest());
                } catch (IOException | RuntimeException ignored) {
                }
            }
        }

        private void startCodec(int width, int height, byte[] parameterSets) throws IOException {
            synchronized (codecLock) {
                lastWidth = width;
                lastHeight = height;
                lastSets = parameterSets;
                startCodecLocked(width, height, parameterSets);
            }
        }

        private void startCodecLocked(int width, int height, byte[] parameterSets) throws IOException {
            stopCodec();
            Surface target = surface;
            byte[] sps = Protocol.findNal(parameterSets, 7), pps = Protocol.findNal(parameterSets, 8);
            if (target == null || sps == null || pps == null) throw new IOException("no surface or parameter sets");
            MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
            format.setByteBuffer("csd-0", ByteBuffer.wrap(sps));
            format.setByteBuffer("csd-1", ByteBuffer.wrap(pps));
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
            format.setInteger(MediaFormat.KEY_PRIORITY, 0);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 << 20);
            codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            codec.configure(format, target, null, 0);
            codec.start();
            needKey = true;
            final MediaCodec c = codec;
            output = new Thread(() -> drain(c), "ukm-display-output");
            output.start();
            ui.post(() -> waiting.setVisibility(View.GONE));
        }

        private void stopCodec() {
            synchronized (codecLock) {
                stopCodecLocked();
            }
        }

        private void stopCodecLocked() {
            MediaCodec c = codec;
            codec = null;
            if (c == null) return;
            try {
                c.stop();
            } catch (RuntimeException ignored) {
            }
            c.release();
            Thread t = output;
            if (t != null) {
                try {
                    t.join(500);
                } catch (InterruptedException ignored) {
                }
            }
            synchronized (queuedAt) {
                queuedAt.clear();
            }
        }

        private void decode(byte[] body) {
            synchronized (codecLock) {
                decodeLocked(body);
            }
        }

        private void decodeLocked(byte[] body) {
            MediaCodec c = codec;
            if (c == null) return;
            boolean key = Protocol.frameIsKey(body);
            if (needKey && !key) return; // wait for the picture to start from a key frame
            try {
                int i = c.dequeueInputBuffer(20_000);
                if (i < 0) { // the decoder is behind: drop, start over at the next key frame
                    needKey = true;
                    send(Protocol.keyFrameRequest());
                    return;
                }
                ByteBuffer buf = c.getInputBuffer(i);
                int length = body.length - Protocol.FRAME_DATA_OFFSET;
                buf.clear();
                buf.put(body, Protocol.FRAME_DATA_OFFSET, length);
                long pts = Protocol.framePtsUs(body);
                synchronized (queuedAt) {
                    queuedAt.put(pts, System.nanoTime());
                }
                c.queueInputBuffer(i, 0, length, pts, 0);
                if (key) needKey = false;
            } catch (RuntimeException e) {
                close();
            }
        }

        /** Shows decoded frames at once and reports the times once a second. */
        private void drain(MediaCodec c) {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            long lastStats = 0;
            try {
                while (!done && codec == c) {
                    int i = c.dequeueOutputBuffer(info, 10_000);
                    if (i < 0) continue;
                    long got = System.nanoTime();
                    c.releaseOutputBuffer(i, true);
                    long shown = System.nanoTime();
                    Long queued;
                    synchronized (queuedAt) {
                        queued = queuedAt.remove(info.presentationTimeUs);
                    }
                    if (queued != null && shown - lastStats > 1_000_000_000L) {
                        lastStats = shown;
                        send(Protocol.stats((got - queued) / 1000, (shown - got) / 1000));
                    }
                }
            } catch (RuntimeException ignored) {
                // The codec was stopped under us.
            }
        }
    }
}

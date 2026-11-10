package com.universalkm.motion;

import android.net.Credentials;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Handler;
import android.util.Log;

import com.universalkm.motion.core.EncodedFrame;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * The live picture for the Mac (design D11). A local socket that only adb (uid shell or root) may use; the
 * Mac reaches it with {@code adb forward tcp:0 localabstract:ukm-motion-live}. A client sends one line,
 * "back" or "front", and gets the encoder's own H.264 frames of that camera — no second encoder, so the
 * live picture costs no extra camera work and never disturbs a recording.
 *
 * <p>Packets, big-endian: {@code 'C' int width, int height, int spsLength, sps, int ppsLength, pps} before the
 * first frame and whenever the encoder changes; {@code 'F' long ptsUs, byte key, short rotation, int length,
 * Annex B data}. Frames start at a key frame; a client that cannot keep up skips to the next key frame.
 */
final class LiveHub {
    static final String SOCKET = "ukm-motion-live";
    private static final String TAG = ClipStore.TAG;
    private static final int QUEUE = 45; // ~1.5 s of frames

    /** Runs on the service's handler when a client comes or goes. */
    interface Listener {
        void clientsChanged();
    }

    private final Handler h;
    private final Listener listener;
    private final List<Client> clients = new CopyOnWriteArrayList<>();
    private LocalServerSocket server;
    private volatile boolean closed;

    LiveHub(Handler h, Listener listener) {
        this.h = h;
        this.listener = listener;
    }

    void start() {
        try {
            server = new LocalServerSocket(SOCKET);
        } catch (IOException e) {
            Log.w(TAG, "live socket", e);
            return;
        }
        Thread t = new Thread(this::acceptLoop, "live-accept");
        t.setDaemon(true);
        t.start();
    }

    void stop() {
        closed = true;
        for (Client c : clients) c.close();
        clients.clear();
        if (server != null) {
            try {
                server.close();
                // accept() does not return on close on every Android version: wake it with a connection.
                LocalSocket wake = new LocalSocket();
                wake.connect(new LocalSocketAddress(SOCKET));
                wake.close();
            } catch (IOException ignored) {
            }
            server = null;
        }
    }

    /** Clients watching the front (true) or the rear (false) camera. */
    int count(boolean front) {
        int n = 0;
        for (Client c : clients) if (c.front == front) n++;
        return n;
    }

    boolean any() {
        return !clients.isEmpty();
    }

    /** One encoded frame of a camera; on the handler thread. */
    void frame(boolean front, EncodedFrame f, byte[] sps, byte[] pps, int width, int height, int rotation) {
        if (clients.isEmpty() || sps == null || pps == null) return;
        byte[] packet = null;
        for (Client c : clients) {
            if (c.front != front) continue;
            if (c.needKey) {
                if (!f.key) continue;
                c.needKey = false;
            }
            if (c.sps != sps || c.pps != pps || c.width != width || c.height != height) {
                c.sps = sps;
                c.pps = pps;
                c.width = width;
                c.height = height;
                if (!f.key) {
                    c.needKey = true;
                    continue;
                }
                c.offer(configPacket(width, height, sps, pps));
            }
            if (packet == null) packet = framePacket(f, rotation);
            c.offer(packet);
        }
    }

    private static byte[] configPacket(int w, int hgt, byte[] sps, byte[] pps) {
        ByteArrayOutputStream b = new ByteArrayOutputStream(32 + sps.length + pps.length);
        DataOutputStream d = new DataOutputStream(b);
        try {
            d.writeByte('C');
            d.writeInt(w);
            d.writeInt(hgt);
            d.writeInt(sps.length);
            d.write(sps);
            d.writeInt(pps.length);
            d.write(pps);
        } catch (IOException ignored) {
        }
        return b.toByteArray();
    }

    private static byte[] framePacket(EncodedFrame f, int rotation) {
        ByteArrayOutputStream b = new ByteArrayOutputStream(16 + f.data.length);
        DataOutputStream d = new DataOutputStream(b);
        try {
            d.writeByte('F');
            d.writeLong(f.ptsUs);
            d.writeByte(f.key ? 1 : 0);
            d.writeShort(rotation);
            d.writeInt(f.data.length);
            d.write(f.data);
        } catch (IOException ignored) {
        }
        return b.toByteArray();
    }

    private void acceptLoop() {
        while (!closed) {
            LocalSocket s;
            try {
                s = server.accept();
            } catch (IOException | RuntimeException e) {
                if (!closed) Log.w(TAG, "live accept", e);
                return;
            }
            if (closed) {
                closeQuietly(s);
                return;
            }
            Thread t = new Thread(() -> serve(s), "live-client");
            t.setDaemon(true);
            t.start();
        }
    }

    /** Only adb may watch (spec «Приватность»): adbd runs as shell, or as root on a rooted device. */
    private void serve(LocalSocket s) {
        try {
            Credentials who = s.getPeerCredentials();
            if (who.getUid() != 2000 && who.getUid() != 0) {
                Log.w(TAG, "live: refused uid " + who.getUid());
                closeQuietly(s);
                return;
            }
            InputStream in = s.getInputStream();
            StringBuilder line = new StringBuilder();
            for (int c; (c = in.read()) != '\n'; ) {
                if (c < 0 || line.length() > 16) throw new IOException("bad request");
                line.append((char) c);
            }
            String which = line.toString().trim();
            if (!which.equals("back") && !which.equals("front")) throw new IOException("bad camera " + which);
            Client client = new Client(s, which.equals("front"));
            clients.add(client);
            Log.i(TAG, "live: watching the " + which + " camera, " + clients.size() + " client(s)");
            h.post(listener::clientsChanged);
            Thread w = new Thread(client::writeLoop, "live-write");
            w.setDaemon(true);
            w.start();
            // The Mac sends nothing more: the read ends when it goes away.
            while (in.read() >= 0) {
                // ignore
            }
            client.close();
        } catch (IOException | RuntimeException e) {
            closeQuietly(s);
        }
    }

    private static void closeQuietly(LocalSocket s) {
        try {
            s.close();
        } catch (IOException ignored) {
        }
    }

    private final class Client {
        final LocalSocket socket;
        final boolean front;
        final ArrayBlockingQueue<byte[]> queue = new ArrayBlockingQueue<>(QUEUE);
        // Only touched on the handler thread.
        boolean needKey = true;
        byte[] sps, pps;
        int width, height;
        private volatile boolean gone;

        Client(LocalSocket socket, boolean front) {
            this.socket = socket;
            this.front = front;
        }

        void offer(byte[] packet) {
            if (queue.offer(packet)) return;
            // Too slow (Wi‑Fi): drop the backlog, go on from the next key frame with a fresh config.
            queue.clear();
            needKey = true;
            sps = pps = null;
        }

        void writeLoop() {
            try {
                OutputStream out = socket.getOutputStream();
                while (!gone) {
                    byte[] p = queue.take();
                    out.write(p);
                    out.flush();
                }
            } catch (IOException | InterruptedException | RuntimeException e) {
                close();
            }
        }

        void close() {
            if (gone) return;
            gone = true;
            queue.offer(new byte[0]);
            closeQuietly(socket);
            if (clients.remove(this)) {
                Log.i(TAG, "live: a client left, " + clients.size() + " left");
                h.post(listener::clientsChanged);
            }
        }
    }
}

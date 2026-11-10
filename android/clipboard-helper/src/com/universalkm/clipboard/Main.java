package com.universalkm.clipboard;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

import org.json.JSONObject;

import android.os.Build;

/**
 * UniversalKM clipboard helper (add-android-clipboard-sync design D1–D3).
 *
 * Started by the Mac app as the shell user:
 *   adb shell CLASSPATH=/data/local/tmp/ukm-clipboard-<sha>.jar app_process / com.universalkm.clipboard.Main
 *
 * Protocol (design D2): one JSON object per line, text as base64 of UTF-8.
 *   in:  {"t":"set","id":N,"b64":"…"}  {"t":"ping"}
 *   out: {"t":"hello","v":1,"sdk":31,"watch":"listener|poll"}  {"t":"changed","b64":"…"}
 *        {"t":"ack","id":N}  {"t":"pong"}  {"t":"error","msg":"…"}
 * Closing stdin ends the process, so nothing keeps running on the phone after the Mac side goes away.
 */
public final class Main {
    /** Must match ClipboardProtocol.version in UniversalKMCore (checked by a unit test). */
    static final int PROTOCOL_VERSION = 1;
    /** Longest text either side sends, in UTF-8 bytes before base64. */
    static final int MAX_TEXT_BYTES = 1 << 20;
    private static final long POLL_MS = 500;

    private static final PrintStream out =
            new PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true);
    private static final Object lock = new Object();
    /** Last text this helper wrote or reported, so its own writes do not come back as "changed". */
    private static String lastText;

    public static void main(String[] args) {
        Clipboard clipboard;
        try {
            clipboard = new Clipboard();
        } catch (Throwable e) {
            send(error("clipboard service: " + e));
            System.exit(2);
            return;
        }
        synchronized (lock) {
            lastText = safeGet(clipboard);
        }
        boolean listening = clipboard.listen(() -> onPhoneChange(clipboard));
        JSONObject hello = obj("hello");
        put(hello, "v", PROTOCOL_VERSION);
        put(hello, "sdk", Build.VERSION.SDK_INT);
        put(hello, "watch", listening ? "listener" : "poll");
        send(hello);
        if (!listening) {
            Thread poller = new Thread(() -> {
                while (true) {
                    try { Thread.sleep(POLL_MS); } catch (InterruptedException e) { return; }
                    onPhoneChange(clipboard);
                }
            }, "ukm-poll");
            poller.setDaemon(true);
            poller.start();
        }
        readCommands(clipboard);
        System.exit(0);
    }

    private static void readCommands(Clipboard clipboard) {
        try (BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            String line;
            while ((line = in.readLine()) != null) {
                if (line.isEmpty()) continue;
                try {
                    handle(clipboard, new JSONObject(line));
                } catch (Throwable e) {
                    send(error("bad command: " + e.getClass().getSimpleName()));
                }
            }
        } catch (Throwable ignored) {
            // stdin gone: the Mac side stopped.
        }
    }

    private static void handle(Clipboard clipboard, JSONObject command) throws Exception {
        String type = command.optString("t");
        if (type.equals("ping")) {
            send(obj("pong"));
        } else if (type.equals("set")) {
            byte[] bytes = Base64.getDecoder().decode(command.getString("b64"));
            if (bytes.length > MAX_TEXT_BYTES) {
                send(error("text too long"));
                return;
            }
            String text = new String(bytes, StandardCharsets.UTF_8);
            synchronized (lock) {
                lastText = text;
            }
            clipboard.set(text);
            JSONObject ack = obj("ack");
            put(ack, "id", command.optLong("id"));
            send(ack);
        } else {
            send(error("unknown command"));
        }
    }

    private static void onPhoneChange(Clipboard clipboard) {
        String text = safeGet(clipboard);
        if (text == null) return;
        synchronized (lock) {
            if (text.equals(lastText)) return;
            lastText = text;
        }
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_TEXT_BYTES) return;
        JSONObject changed = obj("changed");
        put(changed, "b64", Base64.getEncoder().encodeToString(bytes));
        send(changed);
    }

    private static String safeGet(Clipboard clipboard) {
        try {
            return clipboard.getText();
        } catch (Throwable e) {
            return null;
        }
    }

    private static JSONObject obj(String type) {
        JSONObject o = new JSONObject();
        put(o, "t", type);
        return o;
    }

    private static JSONObject error(String message) {
        JSONObject o = obj("error");
        put(o, "msg", message);
        return o;
    }

    private static void put(JSONObject o, String key, Object value) {
        try {
            o.put(key, value);
        } catch (Exception ignored) {
            // Keys and values here are always valid.
        }
    }

    private static void send(JSONObject message) {
        synchronized (out) {
            out.print(message.toString());
            out.print('\n');
            out.flush();
        }
    }
}

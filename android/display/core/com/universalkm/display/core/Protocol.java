package com.universalkm.display.core;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * The wire protocol with the Mac (design D4): {@code u8 type, u32 length, body}, big endian. The Mac's side is
 * Sources/UniversalKMCore/SecondDisplay.swift; both must stay in step (VERSION).
 */
public final class Protocol {
    private Protocol() {}

    public static final int VERSION = 1;
    public static final String SOCKET = "ukm_display";

    public static final int HELLO = 1, CONFIG = 2, FRAME = 3, KEY_FRAME_REQUEST = 4, ROTATED = 5, STATS = 6, TOUCH = 7;
    public static final int TOUCH_DOWN = 0, TOUCH_MOVE = 1, TOUCH_UP = 2;
    private static final int MAX_BODY = 16 << 20;

    /** One message read from the Mac. */
    public static final class Message {
        public final int type;
        public final byte[] body;

        Message(int type, byte[] body) {
            this.type = type;
            this.body = body;
        }
    }

    /** Reads one message; null at a clean end of the stream. */
    public static Message read(InputStream in) throws IOException {
        byte[] head = new byte[5];
        int n = readFully(in, head, 0, 5);
        if (n == 0) return null;
        if (n < 5) throw new IOException("short header");
        long length = u32(head, 1);
        if (length > MAX_BODY) throw new IOException("bad message size " + length);
        byte[] body = new byte[(int) length];
        if (readFully(in, body, 0, body.length) < body.length) throw new IOException("short body");
        return new Message(head[0] & 0xFF, body);
    }

    /** Bytes read, less than {@code len} only at the end of the stream. */
    private static int readFully(InputStream in, byte[] b, int off, int len) throws IOException {
        int got = 0;
        while (got < len) {
            int r = in.read(b, off + got, len - got);
            if (r < 0) break;
            got += r;
        }
        return got;
    }

    // MARK: Messages to the Mac

    public static byte[] hello(int width, int height, boolean hardwareH264) {
        byte[] b = new byte[11];
        put16(b, 0, VERSION);
        put32(b, 2, width);
        put32(b, 6, height);
        b[10] = (byte) (hardwareH264 ? 1 : 0);
        return frame(HELLO, b);
    }

    public static byte[] keyFrameRequest() {
        return frame(KEY_FRAME_REQUEST, new byte[0]);
    }

    public static byte[] rotated(int width, int height) {
        byte[] b = new byte[8];
        put32(b, 0, width);
        put32(b, 4, height);
        return frame(ROTATED, b);
    }

    public static byte[] stats(long decodeUs, long presentUs) {
        byte[] b = new byte[8];
        put32(b, 0, decodeUs);
        put32(b, 4, presentUs);
        return frame(STATS, b);
    }

    /** x and y are 0...65535 over the picture. */
    public static byte[] touch(int action, int fingers, int x, int y, long timeMs) {
        byte[] b = new byte[10];
        b[0] = (byte) action;
        b[1] = (byte) Math.min(fingers, 255);
        put16(b, 2, Math.max(0, Math.min(x, 65535)));
        put16(b, 4, Math.max(0, Math.min(y, 65535)));
        put32(b, 6, timeMs);
        return frame(TOUCH, b);
    }

    // MARK: Messages from the Mac

    /** The size in a CONFIG body. */
    public static int configWidth(byte[] body) { return (int) u32(body, 0); }

    public static int configHeight(byte[] body) { return (int) u32(body, 4); }

    /** The SPS and PPS (Annex B) in a CONFIG body. */
    public static byte[] configParameterSets(byte[] body) {
        byte[] out = new byte[body.length - 8];
        System.arraycopy(body, 8, out, 0, out.length);
        return out;
    }

    public static boolean frameIsKey(byte[] body) { return (body[0] & 1) != 0; }

    public static long framePtsUs(byte[] body) { return u32(body, 1) << 32 | u32(body, 5); }

    /** Offset of the access unit in a FRAME body. */
    public static final int FRAME_DATA_OFFSET = 9;

    // MARK: Annex B

    /** The NAL units of an Annex B buffer, each with its start code kept (what MediaCodec's csd wants). */
    public static List<byte[]> nalUnits(byte[] annexB) {
        List<Integer> starts = new ArrayList<>();
        for (int i = 0; i + 3 <= annexB.length; i++) {
            if (annexB[i] == 0 && annexB[i + 1] == 0 && annexB[i + 2] == 1) {
                // A 4-byte start code has one more zero in front.
                starts.add(i > 0 && annexB[i - 1] == 0 ? i - 1 : i);
                i += 2;
            }
        }
        List<byte[]> out = new ArrayList<>();
        for (int k = 0; k < starts.size(); k++) {
            int from = starts.get(k);
            int to = k + 1 < starts.size() ? starts.get(k + 1) : annexB.length;
            byte[] nal = new byte[to - from];
            System.arraycopy(annexB, from, nal, 0, nal.length);
            out.add(nal);
        }
        return out;
    }

    /** NAL type of a unit with its start code. */
    public static int nalType(byte[] nal) {
        int i = nal[2] == 1 ? 3 : 4;
        return nal[i] & 0x1F;
    }

    /** First NAL of the given type (7 = SPS, 8 = PPS), with its start code; null if there is none. */
    public static byte[] findNal(byte[] annexB, int type) {
        for (byte[] nal : nalUnits(annexB)) if (nalType(nal) == type) return nal;
        return null;
    }

    // MARK: Bytes

    private static byte[] frame(int type, byte[] body) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(5 + body.length);
        out.write(type);
        out.write(body.length >>> 24);
        out.write(body.length >>> 16);
        out.write(body.length >>> 8);
        out.write(body.length);
        out.write(body, 0, body.length);
        return out.toByteArray();
    }

    static long u32(byte[] b, int i) {
        return (b[i] & 0xFFL) << 24 | (b[i + 1] & 0xFFL) << 16 | (b[i + 2] & 0xFFL) << 8 | (b[i + 3] & 0xFFL);
    }

    private static void put16(byte[] b, int i, int v) {
        b[i] = (byte) (v >>> 8);
        b[i + 1] = (byte) v;
    }

    private static void put32(byte[] b, int i, long v) {
        b[i] = (byte) (v >>> 24);
        b[i + 1] = (byte) (v >>> 16);
        b[i + 2] = (byte) (v >>> 8);
        b[i + 3] = (byte) v;
    }
}

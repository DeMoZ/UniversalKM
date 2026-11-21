package com.universalkm.display.core;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.List;

/** Plain-Java checks of the protocol (no Android SDK, no test framework): scripts/build-display-apk.sh --test. */
public final class CoreTests {
    private static int checks = 0;

    private static void check(boolean ok, String what) {
        checks++;
        if (!ok) throw new AssertionError("FAIL: " + what);
    }

    private static byte[] bytes(int... v) {
        byte[] b = new byte[v.length];
        for (int i = 0; i < v.length; i++) b[i] = (byte) v[i];
        return b;
    }

    public static void main(String[] args) throws IOException {
        // The same golden bytes are asserted in the Mac's SecondDisplayTests.goldenBytes.
        check(Arrays.equals(Protocol.hello(2000, 1200, true), bytes(1, 0, 0, 0, 11, 0, 1, 0, 0, 7, 0xD0, 0, 0, 4, 0xB0, 1)), "hello");
        check(Arrays.equals(Protocol.keyFrameRequest(), bytes(4, 0, 0, 0, 0)), "keyFrameRequest");
        check(Arrays.equals(Protocol.rotated(1200, 2000), bytes(5, 0, 0, 0, 8, 0, 0, 4, 0xB0, 0, 0, 7, 0xD0)), "rotated");
        check(Arrays.equals(Protocol.stats(4000, 9000), bytes(6, 0, 0, 0, 8, 0, 0, 0x0F, 0xA0, 0, 0, 0x23, 0x28)), "stats");
        check(Arrays.equals(Protocol.touch(Protocol.TOUCH_DOWN, 1, 65535, 0, 123456),
                bytes(7, 0, 0, 0, 10, 0, 1, 0xFF, 0xFF, 0, 0, 0, 0x01, 0xE2, 0x40)), "touch");
        check(Arrays.equals(Protocol.touch(Protocol.TOUCH_MOVE, 2, 70000, -5, 0),
                bytes(7, 0, 0, 0, 10, 1, 2, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0)), "touch is clamped");

        // A CONFIG and a FRAME as the Mac writes them.
        byte[] sets = bytes(0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE);
        byte[] cfgBody = new byte[8 + sets.length];
        cfgBody[2] = 7; cfgBody[3] = (byte) 0xD0; cfgBody[6] = 4; cfgBody[7] = (byte) 0xB0;
        System.arraycopy(sets, 0, cfgBody, 8, sets.length);
        byte[] stream = concat(bytes(2, 0, 0, 0, cfgBody.length), cfgBody,
                bytes(3, 0, 0, 0, 13, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0x65));
        ByteArrayInputStream in = new ByteArrayInputStream(stream);
        Protocol.Message m = Protocol.read(in);
        check(m.type == Protocol.CONFIG, "config type");
        check(Protocol.configWidth(m.body) == 2000 && Protocol.configHeight(m.body) == 1200, "config size");
        check(Arrays.equals(Protocol.configParameterSets(m.body), sets), "config sets");
        m = Protocol.read(in);
        check(m.type == Protocol.FRAME && Protocol.frameIsKey(m.body), "frame key");
        check(Protocol.framePtsUs(m.body) == 0x1_0000_0001L, "frame pts");
        check(m.body.length - Protocol.FRAME_DATA_OFFSET == 4, "frame data length");
        check(Protocol.read(in) == null, "clean end");

        boolean threw = false;
        try { Protocol.read(new ByteArrayInputStream(bytes(2, 0, 0, 0, 9, 1))); } catch (IOException e) { threw = true; }
        check(threw, "short body is an error");
        threw = false;
        try { Protocol.read(new ByteArrayInputStream(bytes(3, 0xFF, 0xFF, 0xFF, 0xFF))); } catch (IOException e) { threw = true; }
        check(threw, "huge length is an error");

        // Annex B: a 4-byte and a 3-byte start code.
        List<byte[]> nals = Protocol.nalUnits(sets);
        check(nals.size() == 2, "two NAL units");
        check(Protocol.nalType(nals.get(0)) == 7 && Protocol.nalType(nals.get(1)) == 8, "SPS then PPS");
        check(Arrays.equals(Protocol.findNal(sets, 8), bytes(0, 0, 0, 1, 0x68, 0xCE)) || Arrays.equals(Protocol.findNal(sets, 8), bytes(0, 0, 1, 0x68, 0xCE)), "PPS kept with start code");
        check(Protocol.findNal(sets, 5) == null, "no IDR");

        System.out.println("display core: " + checks + " checks passed");
    }

    private static byte[] concat(byte[]... parts) {
        int n = 0;
        for (byte[] p : parts) n += p.length;
        byte[] out = new byte[n];
        int at = 0;
        for (byte[] p : parts) {
            System.arraycopy(p, 0, out, at, p.length);
            at += p.length;
        }
        return out;
    }
}

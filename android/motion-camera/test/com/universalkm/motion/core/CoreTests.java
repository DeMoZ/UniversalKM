package com.universalkm.motion.core;

import java.io.RandomAccessFile;
import java.nio.channels.FileChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

/**
 * Tests of the device-independent core on a plain JVM (scripts/build-motion-apk.sh --test).
 * Arguments: an Annex B H.264 stream with access unit delimiters and an output folder; the script checks the
 * written files with ffprobe.
 */
public final class CoreTests {
    private static int failures;
    private static int checks;

    public static void main(String[] args) throws Exception {
        frameRing();
        clipPolicyPersonWalksThrough();
        clipPolicyTwoPasses();
        clipPolicyLongMotion();
        clipPolicyEmptyRoom();
        detectorStaticNoise();
        detectorMovingSquare();
        detectorLightChange();
        detectorSensitivity();
        nalSplitting();
        if (args.length >= 2) writer(Paths.get(args[0]), Paths.get(args[1]));
        System.out.println(checks + " checks, " + failures + " failures");
        if (failures > 0) System.exit(1);
    }

    private static void check(boolean ok, String what) {
        checks++;
        if (!ok) {
            failures++;
            System.out.println("FAIL: " + what);
        }
    }

    private static final long S = 1_000_000L;
    private static final long FRAME = S / 30;

    // MARK: ring

    private static void frameRing() {
        FrameRing ring = new FrameRing(4 * S);
        ring.add(new EncodedFrame(0, false, new byte[1])); // before any key frame: dropped
        check(ring.size() == 0, "ring drops frames before the first key frame");
        long last = 0;
        for (int i = 0; i < 300; i++) {
            last = i * FRAME;
            ring.add(new EncodedFrame(last, i % 30 == 0, new byte[10]));
        }
        List<EncodedFrame> all = ring.from(0);
        check(all.get(0).key, "ring head is a key frame");
        long span = last - all.get(0).ptsUs;
        check(span >= 4 * S && span < 5 * S + FRAME, "ring keeps 4–5 s, kept " + span);
        List<EncodedFrame> from = ring.from(240 * FRAME + 10);
        check(from.get(0).ptsUs == 240 * FRAME, "from() starts at the key frame before the target");
        check(from.get(from.size() - 1).ptsUs == last, "from() ends at the newest");
    }

    // MARK: clip policy

    /** Simulates a timeline: motion samples at 5/s, frames at 30/s with a key frame each second. */
    private static List<long[]> simulate(ClipPolicy p, long endUs, long[][] motionSpans) {
        List<long[]> clips = new ArrayList<>(); // {start, end}
        long[] open = null;
        FrameRing ring = new FrameRing(5 * S);
        for (long i = 0; i * FRAME < endUs; i++) {
            long t = i * FRAME;
            if (t % (S / 5) < FRAME) {
                boolean moving = false;
                for (long[] m : motionSpans) if (t >= m[0] && t < m[1]) moving = true;
                p.motion(t, moving);
            }
            boolean key = i % 30 == 0;
            ring.add(new EncodedFrame(t, key, new byte[1]));
            switch (p.frame(t, key)) {
                case START: {
                    List<EncodedFrame> pre = ring.from(p.startFromUs());
                    p.started(pre.get(0).ptsUs);
                    open = new long[]{pre.get(0).ptsUs, t};
                    break;
                }
                case WRITE:
                    open[1] = t;
                    break;
                case STOP:
                    clips.add(open);
                    open = null;
                    break;
                case ROLL:
                    clips.add(open);
                    open = new long[]{t, t};
                    break;
                default:
            }
        }
        if (open != null) clips.add(open);
        return clips;
    }

    private static void clipPolicyPersonWalksThrough() {
        ClipPolicy p = new ClipPolicy(3 * S, 10 * S, 600 * S);
        List<long[]> clips = simulate(p, 60 * S, new long[][]{{20 * S, 24 * S}});
        check(clips.size() == 1, "one pass = one clip, got " + clips.size());
        long[] c = clips.get(0);
        check(c[0] <= 17 * S && c[0] >= 16 * S, "clip starts ~3 s before motion: " + c[0]);
        long len = c[1] - c[0];
        check(len >= 16 * S && len <= 19 * S, "clip ≈ 3+4+10 s, got " + len / (double) S);
    }

    private static void clipPolicyTwoPasses() {
        ClipPolicy p = new ClipPolicy(3 * S, 10 * S, 600 * S);
        List<long[]> clips = simulate(p, 80 * S, new long[][]{{20 * S, 23 * S}, {28 * S, 31 * S}});
        check(clips.size() == 1, "two passes 5 s apart = one clip, got " + clips.size());
    }

    private static void clipPolicyLongMotion() {
        ClipPolicy p = new ClipPolicy(3 * S, 10 * S, 600 * S);
        List<long[]> clips = simulate(p, 1600 * S, new long[][]{{10 * S, 1510 * S}});
        check(clips.size() == 3, "25 min of motion = 3 clips, got " + clips.size());
        for (int i = 1; i < clips.size(); i++) {
            long gap = clips.get(i)[0] - clips.get(i - 1)[1];
            check(gap <= FRAME, "no gap between rolled clips: " + gap);
        }
    }

    private static void clipPolicyEmptyRoom() {
        ClipPolicy p = new ClipPolicy(3 * S, 10 * S, 600 * S);
        check(simulate(p, 3600 * S, new long[0][]).isEmpty(), "empty room: no clips");
    }

    // MARK: detector

    private static final int FW = 320, FH = 240;

    private static byte[] noiseFrame(Random r, int base, int noise) {
        byte[] y = new byte[FW * FH];
        for (int i = 0; i < y.length; i++) y[i] = (byte) clamp(base + r.nextInt(2 * noise + 1) - noise);
        return y;
    }

    private static int clamp(int v) {
        return Math.max(0, Math.min(255, v));
    }

    private static void square(byte[] y, int x0, int y0, int size, int value) {
        for (int yy = y0; yy < y0 + size && yy < FH; yy++)
            for (int xx = x0; xx < x0 + size && xx < FW; xx++) y[yy * FW + xx] = (byte) value;
    }

    private static void detectorStaticNoise() {
        for (String s : new String[]{"low", "mid", "high"}) {
            MotionDetector d = new MotionDetector();
            d.setSensitivity(s);
            Random r = new Random(1);
            int hits = 0;
            for (int i = 0; i < 500; i++) if (d.process(noiseFrame(r, 100, 25), FW, FH, FW, 1)) hits++;
            check(hits == 0, "sensor noise is not motion (" + s + "), hits " + hits);
        }
    }

    private static void detectorMovingSquare() {
        MotionDetector d = new MotionDetector();
        Random r = new Random(2);
        for (int i = 0; i < 20; i++) d.process(noiseFrame(r, 100, 10), FW, FH, FW, 1);
        int hits = 0;
        for (int i = 0; i < 20; i++) { // a person-sized block (≈ 1/12 of the frame) crossing
            byte[] y = noiseFrame(r, 100, 10);
            square(y, i * 14, 80, 80, 200);
            if (d.process(y, FW, FH, FW, 1)) hits++;
        }
        check(hits >= 15, "moving block is motion, hits " + hits);
        int after = 0;
        for (int i = 0; i < 30; i++) if (d.process(noiseFrame(r, 100, 10), FW, FH, FW, 1)) after++;
        check(after <= 3, "calm again after the block left, hits " + after);
    }

    private static void detectorLightChange() {
        MotionDetector d = new MotionDetector();
        Random r = new Random(3);
        for (int i = 0; i < 20; i++) d.process(noiseFrame(r, 40, 8), FW, FH, FW, 1);
        int late = 0;
        for (int i = 0; i < 50; i++) { // light on: a bright frame with a different pattern (window, lamp)
            byte[] y = noiseFrame(r, 170, 8);
            square(y, 0, 0, 160, 230);
            boolean m = d.process(y, FW, FH, FW, 1);
            if (m && i >= 25) late++; // 25 frames = 5 s at 5/s
        }
        check(late == 0, "light change is calm within 5 s, late hits " + late);
        MotionDetector e = new MotionDetector();
        for (int i = 0; i < 20; i++) e.process(noiseFrame(r, 100, 8), FW, FH, FW, 1);
        int hits = 0;
        for (int i = 0; i < 20; i++) if (e.process(noiseFrame(r, 130, 8), FW, FH, FW, 1)) hits++;
        check(hits == 0, "even exposure shift is not motion, hits " + hits);
    }

    private static void detectorSensitivity() {
        // A small thing moving (≈ 1 % of the frame, a curtain edge): high and mid see it, low does not.
        int[] hits = new int[3];
        String[] names = {"low", "mid", "high"};
        for (int k = 0; k < 3; k++) {
            MotionDetector d = new MotionDetector();
            d.setSensitivity(names[k]);
            Random r = new Random(4);
            for (int i = 0; i < 20; i++) d.process(noiseFrame(r, 100, 8), FW, FH, FW, 1);
            for (int i = 0; i < 20; i++) {
                byte[] y = noiseFrame(r, 100, 8);
                square(y, 100 + (i % 2) * 28, 100, 28, 220);
                if (d.process(y, FW, FH, FW, 1)) hits[k]++;
            }
        }
        check(hits[0] == 0, "low ignores a small movement, hits " + hits[0]);
        check(hits[2] >= 15, "high sees a small movement, hits " + hits[2]);
    }

    // MARK: NAL and writer

    private static void nalSplitting() {
        byte[] in = {0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6};
        List<int[]> u = FragmentedMp4Writer.nalUnits(in);
        check(u.size() == 3, "three NAL units");
        byte[] avcc = FragmentedMp4Writer.annexBToAvcc(in);
        check(avcc.length == 8 && avcc[3] == 4 && avcc[4] == 0x65, "avcc keeps only the slice");
        check(FragmentedMp4Writer.stripStartCode(new byte[]{0, 0, 0, 1, 0x67, 9}).length == 2, "strip start code");
    }

    /** Splits an Annex B stream at access unit delimiters (type 9). */
    private static List<byte[]> accessUnits(byte[] s) {
        List<byte[]> out = new ArrayList<>();
        List<int[]> nals = FragmentedMp4Writer.nalUnits(s);
        int auStart = -1;
        for (int[] n : nals) {
            int type = s[n[0]] & 0x1F;
            if (type == 9) {
                if (auStart >= 0) out.add(slice(s, auStart, n[0] - 4));
                auStart = n[0] - 4;
            }
        }
        if (auStart >= 0) out.add(slice(s, auStart, s.length));
        return out;
    }

    private static byte[] slice(byte[] s, int a, int b) {
        a = Math.max(0, a);
        byte[] o = new byte[b - a];
        System.arraycopy(s, a, o, 0, o.length);
        return o;
    }

    private static byte[] firstNal(byte[] s, int type) {
        for (int[] n : FragmentedMp4Writer.nalUnits(s))
            if ((s[n[0]] & 0x1F) == type) return slice(s, n[0], n[1]);
        return null;
    }

    private static boolean hasIdr(byte[] au) {
        for (int[] n : FragmentedMp4Writer.nalUnits(au)) if ((au[n[0]] & 0x1F) == 5) return true;
        return false;
    }

    private static void writer(Path h264, Path outDir) throws Exception {
        byte[] stream = Files.readAllBytes(h264);
        byte[] sps = firstNal(stream, 7), pps = firstNal(stream, 8);
        check(sps != null && pps != null, "test stream has SPS and PPS");
        List<byte[]> aus = accessUnits(stream);
        check(aus.size() > 60, "test stream has frames: " + aus.size());
        Files.createDirectories(outDir);
        Path full = outDir.resolve("full.mp4");
        Files.deleteIfExists(full);
        try (RandomAccessFile f = new RandomAccessFile(full.toFile(), "rw"); FileChannel ch = f.getChannel()) {
            FragmentedMp4Writer w = new FragmentedMp4Writer(ch, 320, 240, sps, pps, 90, 1_700_000_000L, false);
            long t = 5_000_000; // camera clock does not start at 0
            for (byte[] au : aus) {
                w.write(t, hasIdr(au), au);
                t += FRAME;
            }
            w.close();
            check(w.samples() == aus.size(), "all samples written");
        }
        // A file cut in the middle of a fragment, as after a power loss.
        byte[] all = Files.readAllBytes(full);
        Path cut = outDir.resolve("cut.mp4");
        Files.write(cut, slice(all, 0, all.length * 6 / 10));
        // A file that was never closed (header durations are zero), as written so far.
        Path open = outDir.resolve("open.mp4");
        Files.deleteIfExists(open);
        try (RandomAccessFile f = new RandomAccessFile(open.toFile(), "rw"); FileChannel ch = f.getChannel()) {
            FragmentedMp4Writer w = new FragmentedMp4Writer(ch, 320, 240, sps, pps, 0, 1_700_000_000L, false);
            long t = 0;
            for (byte[] au : aus) {
                w.write(t, hasIdr(au), au);
                t += FRAME;
            }
        }
        System.out.println("writer: " + aus.size() + " frames → " + full + ", " + cut + ", " + open);
    }
}

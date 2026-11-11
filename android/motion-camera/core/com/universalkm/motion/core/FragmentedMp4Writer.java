package com.universalkm.motion.core;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * A fragmented MP4 with one H.264 track (design D4). {@code ftyp} and {@code moov} go first, then one
 * {@code moof}+{@code mdat} per key-frame interval, each followed by a sync to disk, so a file cut short by a
 * power loss plays up to its last whole fragment. {@link #close} writes the total duration into {@code mehd}.
 */
public final class FragmentedMp4Writer {
    public static final int TIMESCALE = 90_000;
    private static final int MOVIE_TIMESCALE = 1000;
    private static final long MAC_EPOCH = 2_082_844_800L; // seconds 1904 → 1970
    private static final long DEFAULT_DURATION = TIMESCALE / 30;

    private final FileChannel out;
    private final boolean sync;
    private long position;
    private int sequence;
    private long firstPtsUs = -1;
    private long lastDecode = -1;
    private long lastDuration = DEFAULT_DURATION;
    private long fragmentBase = -1;
    private final List<long[]> pending = new ArrayList<>(); // {decodeTime, size, key}
    private final ByteArrayOutputStream pendingData = new ByteArrayOutputStream();
    private long samples;

    // Offsets of the duration fields patched in close().
    private long mehdDurationAt;

    /**
     * @param sps,pps parameter sets without start codes
     * @param rotation 0, 90, 180 or 270: how players turn the picture
     * @param sync whether to force each fragment to disk (true on the device)
     */
    public FragmentedMp4Writer(FileChannel out, int width, int height, byte[] sps, byte[] pps, int rotation,
                               long creationUnixSeconds, boolean sync) throws IOException {
        this.out = out;
        this.sync = sync;
        long t = creationUnixSeconds + MAC_EPOCH;
        writeHeader(width, height, sps, pps, rotation, t);
    }

    /** Number of samples written so far (in closed and open fragments). */
    public long samples() {
        return samples;
    }

    /** Bytes in the file so far, including the open fragment. */
    public long bytes() {
        return position + pendingData.size();
    }

    /** One access unit in Annex B form. The first one must be a key frame. */
    public void write(long ptsUs, boolean key, byte[] annexB) throws IOException {
        if (firstPtsUs < 0) {
            if (!key) return;
            firstPtsUs = ptsUs;
        }
        long decode = (ptsUs - firstPtsUs) * TIMESCALE / 1_000_000L;
        if (decode <= lastDecode) decode = lastDecode + 1; // keep time moving forward
        if (key && !pending.isEmpty()) flushFragment(decode);
        byte[] avcc = annexBToAvcc(annexB);
        if (avcc.length == 0) return;
        if (pending.isEmpty()) fragmentBase = decode;
        pending.add(new long[]{decode, avcc.length, key ? 1 : 0});
        pendingData.write(avcc);
        if (lastDecode >= 0) lastDuration = decode - lastDecode;
        lastDecode = decode;
        samples++;
    }

    /** Writes the open fragment and the total duration. The channel stays open. */
    public void close() throws IOException {
        long end = lastDecode < 0 ? 0 : lastDecode + Math.max(1, lastDuration);
        if (!pending.isEmpty()) flushFragment(end);
        long movieDuration = end * MOVIE_TIMESCALE / TIMESCALE;
        // Only mehd: mvhd/tkhd/mdhd describe samples inside moov (none here); AVFoundation adds them to the
        // fragments, so a filled-in mvhd would double the duration.
        patch32(mehdDurationAt, movieDuration);
        if (sync) out.force(true);
    }

    // MARK: fragments

    private void flushFragment(long nextDecode) throws IOException {
        int n = pending.size();
        Box trun = new Box("trun");
        trun.u32(0x000701); // data-offset, duration, size, flags present
        trun.u32(n);
        int dataOffsetAt = trun.size();
        trun.u32(0); // data offset, filled below
        for (int i = 0; i < n; i++) {
            long[] s = pending.get(i);
            long next = i + 1 < n ? pending.get(i + 1)[0] : nextDecode;
            trun.u32(Math.max(1, next - s[0]));
            trun.u32(s[1]);
            trun.u32(s[2] == 1 ? 0x02000000 : 0x01010000);
        }
        Box tfhd = new Box("tfhd");
        tfhd.u32(0x020000); // default-base-is-moof
        tfhd.u32(1);
        Box tfdt = new Box("tfdt");
        tfdt.u32(0x01000000); // version 1
        tfdt.u64(fragmentBase);
        Box traf = new Box("traf").add(tfhd).add(tfdt).add(trun);
        Box mfhd = new Box("mfhd");
        mfhd.u32(0);
        mfhd.u32(++sequence);
        Box moof = new Box("moof").add(mfhd).add(traf);
        byte[] moofBytes = moof.bytes();
        // trun's data offset: from the start of moof to the first sample byte in mdat.
        int trunStart = indexOf(moofBytes, "trun") - 4;
        int at = trunStart + 8 + dataOffsetAt;
        putInt(moofBytes, at, moofBytes.length + 8);

        byte[] data = pendingData.toByteArray();
        ByteBuffer mdatHeader = ByteBuffer.allocate(8);
        mdatHeader.putInt(8 + data.length).put("mdat".getBytes(StandardCharsets.US_ASCII)).flip();
        writeAll(ByteBuffer.wrap(moofBytes));
        writeAll(mdatHeader);
        writeAll(ByteBuffer.wrap(data));
        if (sync) out.force(false);
        pending.clear();
        pendingData.reset();
    }

    // MARK: header

    private void writeHeader(int width, int height, byte[] sps, byte[] pps, int rotation, long time)
            throws IOException {
        Box ftyp = new Box("ftyp");
        ftyp.ascii("isom");
        ftyp.u32(0x200);
        ftyp.ascii("isom").ascii("iso6").ascii("avc1").ascii("mp41");
        writeAll(ByteBuffer.wrap(ftyp.bytes()));

        Box mvhd = new Box("mvhd");
        mvhd.u32(0);
        mvhd.u32(time).u32(time).u32(MOVIE_TIMESCALE);
        mvhd.u32(0); // duration: 0, the samples are in fragments
        mvhd.u32(0x00010000).u16(0x0100).zeros(10);
        matrix(mvhd, 0);
        mvhd.zeros(24).u32(2);

        Box tkhd = new Box("tkhd");
        tkhd.u32(0x000003);
        tkhd.u32(time).u32(time).u32(1).u32(0);
        tkhd.u32(0).zeros(8).u16(0).u16(0).u16(0).u16(0);
        matrix(tkhd, rotation);
        tkhd.u32((long) width << 16).u32((long) height << 16);

        Box mdhd = new Box("mdhd");
        mdhd.u32(0).u32(time).u32(time).u32(TIMESCALE);
        mdhd.u32(0).u16(0x55C4).u16(0); // language "und"

        Box hdlr = new Box("hdlr");
        hdlr.u32(0).u32(0).ascii("vide").zeros(12).ascii("VideoHandler").zeros(1);

        Box vmhd = new Box("vmhd");
        vmhd.u32(1).zeros(8);
        Box url = new Box("url ");
        url.u32(1);
        Box dref = new Box("dref");
        dref.u32(0).u32(1).add(url);
        Box dinf = new Box("dinf").add(dref);

        Box avcC = new Box("avcC");
        avcC.u8(1).u8(sps[1] & 0xFF).u8(sps[2] & 0xFF).u8(sps[3] & 0xFF).u8(0xFF).u8(0xE1);
        avcC.u16(sps.length).raw(sps).u8(1).u16(pps.length).raw(pps);
        Box avc1 = new Box("avc1");
        avc1.zeros(6).u16(1).zeros(16).u16(width).u16(height).u32(0x00480000).u32(0x00480000).u32(0).u16(1);
        avc1.zeros(32).u16(0x0018).u16(0xFFFF).add(avcC);
        Box stsd = new Box("stsd");
        stsd.u32(0).u32(1).add(avc1);
        Box stts = new Box("stts");
        stts.u32(0).u32(0);
        Box stsc = new Box("stsc");
        stsc.u32(0).u32(0);
        Box stsz = new Box("stsz");
        stsz.u32(0).u32(0).u32(0);
        Box stco = new Box("stco");
        stco.u32(0).u32(0);
        Box stbl = new Box("stbl").add(stsd).add(stts).add(stsc).add(stsz).add(stco);
        Box minf = new Box("minf").add(vmhd).add(dinf).add(stbl);
        Box mdia = new Box("mdia").add(mdhd).add(hdlr).add(minf);
        Box trak = new Box("trak").add(tkhd).add(mdia);

        Box mehd = new Box("mehd");
        mehd.u32(0);
        int mehdDur = mehd.size();
        mehd.u32(0);
        Box trex = new Box("trex");
        trex.u32(0).u32(1).u32(1).u32(0).u32(0).u32(0);
        Box mvex = new Box("mvex").add(mehd).add(trex);
        Box moov = new Box("moov").add(mvhd).add(trak).add(mvex);

        byte[] bytes = moov.bytes();
        long base = position;
        mehdDurationAt = base + find(bytes, "mehd") + 8 + mehdDur;
        writeAll(ByteBuffer.wrap(bytes));
    }

    private static void matrix(Box b, int rotation) {
        int one = 0x00010000, minus = 0xFFFF0000;
        int a, bb, c, d;
        switch (((rotation % 360) + 360) % 360) {
            case 90: a = 0; bb = one; c = minus; d = 0; break;
            case 180: a = minus; bb = 0; c = 0; d = minus; break;
            case 270: a = 0; bb = minus; c = one; d = 0; break;
            default: a = one; bb = 0; c = 0; d = one;
        }
        b.u32(a & 0xFFFFFFFFL).u32(bb & 0xFFFFFFFFL).u32(0);
        b.u32(c & 0xFFFFFFFFL).u32(d & 0xFFFFFFFFL).u32(0);
        b.u32(0).u32(0).u32(0x40000000);
    }

    // MARK: NAL units

    /** Annex B (start codes) → 4-byte length prefixes; parameter sets and delimiters are dropped. */
    static byte[] annexBToAvcc(byte[] in) {
        ByteArrayOutputStream o = new ByteArrayOutputStream(in.length + 16);
        for (int[] nal : nalUnits(in)) {
            int type = in[nal[0]] & 0x1F;
            if (type == 7 || type == 8 || type == 9) continue;
            int len = nal[1] - nal[0];
            o.write(len >>> 24);
            o.write(len >>> 16);
            o.write(len >>> 8);
            o.write(len);
            o.write(in, nal[0], len);
        }
        return o.toByteArray();
    }

    /** {start, end} of each NAL unit payload. Input without start codes is one unit. */
    public static List<int[]> nalUnits(byte[] in) {
        List<int[]> out = new ArrayList<>();
        int i = 0, start = -1;
        while (i + 2 < in.length) {
            if (in[i] == 0 && in[i + 1] == 0 && (in[i + 2] == 1 || (in[i + 2] == 0 && i + 3 < in.length && in[i + 3] == 1))) {
                int codeLen = in[i + 2] == 1 ? 3 : 4;
                if (start >= 0) out.add(new int[]{start, trimEnd(in, start, i)});
                i += codeLen;
                start = i;
            } else {
                i++;
            }
        }
        if (start < 0) {
            if (in.length > 0) out.add(new int[]{0, in.length});
        } else if (start < in.length) {
            out.add(new int[]{start, in.length});
        }
        return out;
    }

    private static int trimEnd(byte[] in, int start, int end) {
        while (end > start && in[end - 1] == 0) end--;
        return end;
    }

    /** The payload of the first NAL unit (strips a start code if there is one). */
    public static byte[] stripStartCode(byte[] in) {
        List<int[]> u = nalUnits(in);
        if (u.isEmpty()) return in;
        int[] n = u.get(0);
        byte[] out = new byte[n[1] - n[0]];
        System.arraycopy(in, n[0], out, 0, out.length);
        return out;
    }

    // MARK: IO

    private void writeAll(ByteBuffer b) throws IOException {
        while (b.hasRemaining()) position += out.write(b, position);
    }

    private void patch32(long at, long value) throws IOException {
        ByteBuffer b = ByteBuffer.allocate(4);
        b.putInt((int) Math.min(value, 0xFFFFFFFFL)).flip();
        long p = at;
        while (b.hasRemaining()) p += out.write(b, p);
    }

    private static int find(byte[] b, String type) {
        int i = indexOf(b, type);
        if (i < 0) throw new IllegalStateException(type);
        return i - 4;
    }

    private static int indexOf(byte[] b, String type) {
        byte[] t = type.getBytes(StandardCharsets.US_ASCII);
        outer:
        for (int i = 4; i + 4 <= b.length; i++) {
            for (int j = 0; j < 4; j++) if (b[i + j] != t[j]) continue outer;
            return i;
        }
        return -1;
    }

    private static void putInt(byte[] b, int at, int v) {
        b[at] = (byte) (v >>> 24);
        b[at + 1] = (byte) (v >>> 16);
        b[at + 2] = (byte) (v >>> 8);
        b[at + 3] = (byte) v;
    }

    /** An MP4 box under construction: size and type are added by {@link #bytes()}. */
    static final class Box {
        private final String type;
        private final ByteArrayOutputStream body = new ByteArrayOutputStream();

        Box(String type) {
            this.type = type;
        }

        int size() {
            return body.size();
        }

        Box u8(int v) {
            body.write(v);
            return this;
        }

        Box u16(int v) {
            body.write(v >>> 8);
            body.write(v);
            return this;
        }

        Box u32(long v) {
            body.write((int) (v >>> 24));
            body.write((int) (v >>> 16));
            body.write((int) (v >>> 8));
            body.write((int) v);
            return this;
        }

        Box u64(long v) {
            return u32(v >>> 32).u32(v & 0xFFFFFFFFL);
        }

        Box zeros(int n) {
            for (int i = 0; i < n; i++) body.write(0);
            return this;
        }

        Box ascii(String s) {
            byte[] b = s.getBytes(StandardCharsets.US_ASCII);
            body.write(b, 0, b.length);
            return this;
        }

        Box raw(byte[] b) {
            body.write(b, 0, b.length);
            return this;
        }

        Box add(Box child) {
            return raw(child.bytes());
        }

        byte[] bytes() {
            byte[] b = body.toByteArray();
            ByteBuffer o = ByteBuffer.allocate(8 + b.length);
            o.putInt(8 + b.length).put(type.getBytes(StandardCharsets.US_ASCII)).put(b);
            return o.array();
        }
    }
}

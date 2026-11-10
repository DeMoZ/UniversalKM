package com.universalkm.motion.core;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

/**
 * The last few seconds of encoded frames (design D4, pre-roll). The head always starts at a key frame,
 * so a clip can begin with any frame {@link #from} returns.
 */
public final class FrameRing {
    private final ArrayDeque<EncodedFrame> frames = new ArrayDeque<>();
    private final long keepUs;

    /** Keeps at least {@code keepUs} before the newest frame, starting at a key frame. */
    public FrameRing(long keepUs) {
        this.keepUs = keepUs;
    }

    public void add(EncodedFrame frame) {
        if (frames.isEmpty() && !frame.key) return; // nothing decodable before the first key frame
        frames.addLast(frame);
        trim(frame.ptsUs);
    }

    /** Drops everything before the latest key frame that is still at least keepUs old. */
    private void trim(long newestUs) {
        EncodedFrame cut = null;
        for (EncodedFrame f : frames) {
            if (newestUs - f.ptsUs < keepUs) break;
            if (f.key) cut = f;
        }
        if (cut == null) return;
        while (frames.peekFirst() != cut) frames.removeFirst();
    }

    /**
     * Frames from the latest key frame at or before {@code targetUs} up to the newest one; from the oldest key
     * frame if all are later. Empty when there are no frames.
     */
    public List<EncodedFrame> from(long targetUs) {
        EncodedFrame start = null;
        for (EncodedFrame f : frames) {
            if (!f.key) continue;
            if (start == null || f.ptsUs <= targetUs) start = f;
            if (f.ptsUs > targetUs) break;
        }
        List<EncodedFrame> out = new ArrayList<>();
        if (start == null) return out;
        boolean on = false;
        for (Iterator<EncodedFrame> it = frames.iterator(); it.hasNext(); ) {
            EncodedFrame f = it.next();
            if (f == start) on = true;
            if (on) out.add(f);
        }
        return out;
    }

    public int size() {
        return frames.size();
    }

    public long bytes() {
        long n = 0;
        for (EncodedFrame f : frames) n += f.data.length;
        return n;
    }

    public void clear() {
        frames.clear();
    }
}

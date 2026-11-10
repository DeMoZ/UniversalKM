package com.universalkm.motion.core;

/** One encoded H.264 access unit as the encoder gave it (Annex B, start codes). */
public final class EncodedFrame {
    public final long ptsUs;
    public final boolean key;
    public final byte[] data;

    public EncodedFrame(long ptsUs, boolean key, byte[] data) {
        this.ptsUs = ptsUs;
        this.key = key;
        this.data = data;
    }
}

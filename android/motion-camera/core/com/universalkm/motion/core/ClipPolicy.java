package com.universalkm.motion.core;

/**
 * When a clip starts, goes on, rolls over to the next file and stops (spec «Запись по движению»,
 * «Долгое движение и смена света»). Times are camera timestamps in microseconds; motion samples and
 * encoded frames share that clock.
 */
public final class ClipPolicy {
    public enum Action {
        /** Not recording; keep the frame in the ring only. */
        NONE,
        /** Open a clip and write the ring from {@link #startFromUs()}; then call {@link #started}. */
        START,
        /** Write this frame to the open clip. */
        WRITE,
        /** Close the clip; this frame is not part of it. */
        STOP,
        /** Close the clip and open the next one starting with this key frame. */
        ROLL
    }

    private volatile long preRollUs;
    private volatile long stopDelayUs;
    private final long maxClipUs;

    private boolean recording;
    private long lastMotionUs = Long.MIN_VALUE;
    private long triggerUs = -1;
    private long clipStartUs;

    public ClipPolicy(long preRollUs, long stopDelayUs, long maxClipUs) {
        this.preRollUs = preRollUs;
        this.stopDelayUs = stopDelayUs;
        this.maxClipUs = maxClipUs;
    }

    public void setStopDelayUs(long us) {
        stopDelayUs = us;
    }

    public void setPreRollUs(long us) {
        preRollUs = us;
    }

    public synchronized void motion(long tUs, boolean moving) {
        if (!moving) return;
        lastMotionUs = Math.max(lastMotionUs, tUs);
        if (!recording && triggerUs < 0) triggerUs = tUs;
    }

    public synchronized Action frame(long ptsUs, boolean key) {
        if (!recording) {
            if (triggerUs < 0) return Action.NONE;
            recording = true;
            return Action.START;
        }
        if (lastMotionUs == Long.MIN_VALUE || ptsUs - lastMotionUs > stopDelayUs) {
            recording = false;
            triggerUs = -1;
            return Action.STOP;
        }
        if (key && ptsUs - clipStartUs >= maxClipUs) {
            clipStartUs = ptsUs;
            return Action.ROLL;
        }
        return Action.WRITE;
    }

    /** Where the pre-roll of the clip that START opens begins. */
    public synchronized long startFromUs() {
        return triggerUs - preRollUs;
    }

    /** The clip opened by START begins with the frame at {@code firstPtsUs}. */
    public synchronized void started(long firstPtsUs) {
        clipStartUs = firstPtsUs;
    }

    /** START could not be done yet (no key frame): try again on the next frame. */
    public synchronized void deferStart() {
        recording = false;
    }

    /** Forget the pending trigger or the open clip (camera stopped, no space). */
    public synchronized void reset() {
        recording = false;
        triggerUs = -1;
        lastMotionUs = Long.MIN_VALUE;
    }

    public synchronized boolean isRecording() {
        return recording;
    }
}

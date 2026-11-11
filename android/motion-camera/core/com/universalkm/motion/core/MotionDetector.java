package com.universalkm.motion.core;

/**
 * Motion in the luma plane (design D4). Each frame is averaged down to 80×60 and compared with a slowly
 * adapting background. Global brightness shifts (auto exposure) are taken out first; a frame where most of
 * the picture changed is a light change: the background jumps to it and it does not count as motion.
 */
public final class MotionDetector {
    public static final int W = 80;
    public static final int H = 60;

    /** A point changed when it differs from the background by more than this (0–255). */
    public static final int DIFF = 20;
    /** More than this share changed = the light changed, not motion. */
    public static final double LIGHT_CHANGE = 0.6;
    /** Background follows calm points by 1/ADAPT per analysed frame… */
    public static final int ADAPT = 8;
    /** …and changed points by 1/ADAPT_CHANGED: a passer-by leaves no ghost, a thing left behind fades in ~20 s. */
    public static final int ADAPT_CHANGED = 64;
    /** Motion needs this many analysed frames in a row. */
    public static final int CONSECUTIVE = 2;

    private final float[] bg = new float[W * H];
    private final int[] small = new int[W * H];
    private boolean hasBg;
    private int run;
    private volatile double threshold = sensitivityThreshold("mid");
    private double lastFraction;

    /** Share of changed points that counts as motion for "low", "mid", "high". */
    public static double sensitivityThreshold(String sensitivity) {
        if ("low".equals(sensitivity)) return 0.02;
        if ("high".equals(sensitivity)) return 0.0025;
        return 0.007;
    }

    public void setSensitivity(String sensitivity) {
        threshold = sensitivityThreshold(sensitivity);
    }

    /** Share of points that changed in the last frame (for logs and tuning). */
    public double lastFraction() {
        return lastFraction;
    }

    public void reset() {
        hasBg = false;
        run = 0;
    }

    /**
     * One luma plane of {@code width}×{@code height} with {@code rowStride} bytes per row
     * ({@code pixelStride} bytes between points). Returns true while there is motion.
     */
    public boolean process(byte[] y, int width, int height, int rowStride, int pixelStride) {
        downscale(y, width, height, rowStride, pixelStride);
        return analyse();
    }

    private void downscale(byte[] y, int width, int height, int rowStride, int pixelStride) {
        for (int by = 0; by < H; by++) {
            int y0 = by * height / H, y1 = Math.max(y0 + 1, (by + 1) * height / H);
            for (int bx = 0; bx < W; bx++) {
                int x0 = bx * width / W, x1 = Math.max(x0 + 1, (bx + 1) * width / W);
                int sum = 0, n = 0;
                for (int yy = y0; yy < y1; yy++) {
                    int row = yy * rowStride;
                    for (int xx = x0; xx < x1; xx++) {
                        sum += y[row + xx * pixelStride] & 0xFF;
                        n++;
                    }
                }
                small[by * W + bx] = sum / n;
            }
        }
    }

    private boolean analyse() {
        if (!hasBg) {
            for (int i = 0; i < small.length; i++) bg[i] = small[i];
            hasBg = true;
            run = 0;
            lastFraction = 0;
            return false;
        }
        double meanNow = 0, meanBg = 0;
        for (int i = 0; i < small.length; i++) {
            meanNow += small[i];
            meanBg += bg[i];
        }
        float shift = (float) ((meanNow - meanBg) / small.length);
        int changed = 0;
        for (int i = 0; i < small.length; i++) {
            if (Math.abs(small[i] - bg[i] - shift) > DIFF) changed++;
        }
        double fraction = (double) changed / small.length;
        lastFraction = fraction;
        if (fraction > LIGHT_CHANGE) {
            for (int i = 0; i < small.length; i++) bg[i] = small[i];
            run = 0;
            return false;
        }
        for (int i = 0; i < small.length; i++) {
            float d = small[i] - bg[i];
            bg[i] += Math.abs(d - shift) > DIFF ? d / ADAPT_CHANGED : d / ADAPT;
        }
        run = fraction > threshold ? run + 1 : 0;
        return run >= CONSECUTIVE;
    }
}

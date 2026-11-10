package com.universalkm.motion;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.os.StatFs;
import android.provider.MediaStore;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * Clips in Movies/UniversalKM Motion through MediaStore (design D7). Without media permissions the app sees
 * only rows it created, so the clean-up can never touch someone else's file.
 *
 * A clip being written is named {@code 2026-11-10_14-32-05 (recording).mp4} and gets its real name when it is
 * closed. IS_PENDING is not used: MediaProvider deletes pending rows when the app's process is killed or the
 * app is updated, and the part already written would be lost. A hidden name (leading dot) does not work either:
 * MediaProvider turns such a row into a non-media one, and the rename then leaves it behind and creates a new
 * row without an owner, which the app can no longer see or delete.
 */
final class ClipStore {
    static final String TAG = "UKMMotion";
    static final String DIR = Environment.DIRECTORY_MOVIES + "/UniversalKM Motion/";
    static final long MIN_FREE = 500L * 1024 * 1024;
    static final String RECORDING = " (recording).mp4";

    static final class Clip {
        final Uri uri;
        final ParcelFileDescriptor pfd;
        final FileChannel channel;
        final String name;

        Clip(Uri uri, ParcelFileDescriptor pfd, FileChannel channel, String name) {
            this.uri = uri;
            this.pfd = pfd;
            this.channel = channel;
            this.name = name;
        }
    }

    private final ContentResolver cr;
    private final Uri collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY);

    ClipStore(Context c) {
        cr = c.getContentResolver();
    }

    static String fileName(long millis) {
        return new SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US).format(new Date(millis)) + ".mp4";
    }

    Clip open(long startMillis) throws IOException {
        String name = fileName(startMillis);
        ContentValues v = new ContentValues();
        v.put(MediaStore.MediaColumns.DISPLAY_NAME, name.replace(".mp4", RECORDING));
        v.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
        v.put(MediaStore.MediaColumns.RELATIVE_PATH, DIR);
        v.put(MediaStore.Video.VideoColumns.DATE_TAKEN, startMillis);
        Uri uri = cr.insert(collection, v);
        if (uri == null) throw new IOException("MediaStore insert failed");
        ParcelFileDescriptor pfd = cr.openFileDescriptor(uri, "rw");
        if (pfd == null) {
            cr.delete(uri, null, null);
            throw new IOException("no file descriptor");
        }
        // Closing this channel closes the stream and the ParcelFileDescriptor once, so MediaProvider learns
        // the write is over. (A plain FileOutputStream on pfd.getFileDescriptor() closes the descriptor behind
        // pfd's back: MediaProvider then never sees the close and does not follow the rename.)
        FileChannel ch = new ParcelFileDescriptor.AutoCloseOutputStream(pfd).getChannel();
        return new Clip(uri, pfd, ch, name);
    }

    /** MediaProvider scans a file when it is closed; a rename during that scan loses the row (see rename). */
    static final long RENAME_DELAY_MS = 3000;

    /**
     * Closes the file; a clip with frames gets its real name {@link #RENAME_DELAY_MS} later on {@code later},
     * an empty one is removed. If the app stops before that, {@link #recoverPending} renames it on the next start.
     */
    void finish(Clip c, boolean keep, android.os.Handler later) {
        try {
            c.channel.close();
        } catch (IOException e) {
            Log.w(TAG, "close " + c.name, e);
        }
        try {
            if (keep) {
                later.postDelayed(() -> rename(c.uri, c.name), RENAME_DELAY_MS);
            } else {
                cr.delete(c.uri, null, null);
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "finish " + c.name, e);
        }
    }

    /**
     * Gives a closed clip its real name; " 2" if the name is taken. On a Galaxy Tab A9 (Android 16) a rename right
     * after the file was closed moved the file but dropped its row; the scanner then made a new row without an
     * owner, which the app can no longer see or delete. A few seconds later the rename keeps the row.
     */
    private void rename(Uri uri, String name) {
        for (int i = 1; i <= 9; i++) {
            String n = i == 1 ? name : name.replace(".mp4", " " + i + ".mp4");
            ContentValues v = new ContentValues();
            v.put(MediaStore.MediaColumns.DISPLAY_NAME, n);
            try {
                if (cr.update(uri, v, null, null) > 0) return;
            } catch (RuntimeException e) {
                Log.w(TAG, "rename to " + n + ": " + e);
            }
        }
    }

    /** The file of a row is gone (deleted from the Mac, or moved away): the row can go too. */
    private boolean fileMissing(Uri uri) {
        try (Cursor c = cr.query(uri, new String[]{MediaStore.MediaColumns.DATA}, null, null, null)) {
            if (c != null && c.moveToFirst() && c.getString(0) != null) return !new File(c.getString(0)).exists();
        } catch (RuntimeException e) {
            Log.w(TAG, "path", e);
        }
        return false;
    }

    /**
     * After a power loss or a killed process the clip that was being written is still "(recording)": give it its
     * real name (or drop it if empty). IS_PENDING rows from an early build are published too.
     */
    void recoverPending() {
        try (Cursor cur = cr.query(collection,
                new String[]{MediaStore.MediaColumns._ID, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DISPLAY_NAME},
                MediaStore.MediaColumns.RELATIVE_PATH + "=? AND " + MediaStore.MediaColumns.DISPLAY_NAME + " LIKE ?",
                new String[]{DIR, "%" + RECORDING}, null)) {
            while (cur != null && cur.moveToNext()) {
                Uri uri = ContentUris.withAppendedId(collection, cur.getLong(0));
                String name = cur.getString(2).replace(RECORDING, ".mp4");
                if (fileMissing(uri)) {
                    cr.delete(uri, null, null);
                } else if (cur.getLong(1) > 0) {
                    rename(uri, name);
                    Log.i(TAG, "recovered a clip cut short: " + name);
                } else {
                    cr.delete(uri, null, null);
                }
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "recover hidden", e);
        }
        Bundle q = new Bundle();
        q.putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, MediaStore.MediaColumns.RELATIVE_PATH + "=?");
        q.putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, new String[]{DIR});
        q.putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_ONLY);
        try (Cursor cur = cr.query(collection, new String[]{MediaStore.MediaColumns._ID, MediaStore.MediaColumns.SIZE}, q, null)) {
            if (cur == null) return;
            while (cur.moveToNext()) {
                Uri uri = ContentUris.withAppendedId(collection, cur.getLong(0));
                if (cur.getLong(1) > 0) {
                    ContentValues v = new ContentValues();
                    v.put(MediaStore.MediaColumns.IS_PENDING, 0);
                    cr.update(uri, v, null, null);
                    Log.i(TAG, "recovered a clip cut short");
                } else {
                    cr.delete(uri, null, null);
                }
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "recoverPending", e);
        }
    }

    /** {id, size} of finished clips, oldest first. */
    private List<long[]> clips() {
        List<long[]> out = new ArrayList<>();
        try (Cursor cur = cr.query(collection,
                new String[]{MediaStore.MediaColumns._ID, MediaStore.MediaColumns.SIZE},
                // Not the clip being written.
                MediaStore.MediaColumns.RELATIVE_PATH + "=? AND " + MediaStore.MediaColumns.DISPLAY_NAME + " NOT LIKE ?",
                new String[]{DIR, "%" + RECORDING},
                MediaStore.MediaColumns.DATE_ADDED + " ASC, " + MediaStore.MediaColumns.DISPLAY_NAME + " ASC")) {
            if (cur == null) return out;
            while (cur.moveToNext()) out.add(new long[]{cur.getLong(0), cur.getLong(1)});
        } catch (RuntimeException e) {
            Log.w(TAG, "clips", e);
        }
        return out;
    }

    /** {count, bytes} of finished clips. */
    long[] usage() {
        long n = 0, bytes = 0;
        for (long[] c : clips()) {
            if (c[1] <= 0) continue;
            n++;
            bytes += c[1];
        }
        return new long[]{n, bytes};
    }

    /** Deletes the oldest clips until they take no more than {@code limitBytes} together with {@code extra}. */
    void enforceLimit(long limitBytes, long extra) {
        List<long[]> all = clips();
        long total = extra;
        for (long[] c : all) total += Math.max(0, c[1]);
        for (long[] c : all) {
            if (total <= limitBytes) break;
            try {
                cr.delete(ContentUris.withAppendedId(collection, c[0]), null, null);
                total -= Math.max(0, c[1]);
                Log.i(TAG, "deleted an old clip, " + c[1] + " bytes");
            } catch (RuntimeException e) {
                Log.w(TAG, "delete", e);
            }
        }
    }

    static long freeBytes() {
        try {
            return new StatFs(Environment.getExternalStorageDirectory().getPath()).getAvailableBytes();
        } catch (RuntimeException e) {
            return Long.MAX_VALUE;
        }
    }
}

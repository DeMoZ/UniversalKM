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
 */
final class ClipStore {
    static final String TAG = "UKMMotion";
    static final String DIR = Environment.DIRECTORY_MOVIES + "/UniversalKM Motion/";
    static final long MIN_FREE = 500L * 1024 * 1024;

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
        v.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
        v.put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4");
        v.put(MediaStore.MediaColumns.RELATIVE_PATH, DIR);
        v.put(MediaStore.MediaColumns.IS_PENDING, 1);
        v.put(MediaStore.Video.VideoColumns.DATE_TAKEN, startMillis);
        Uri uri = cr.insert(collection, v);
        if (uri == null) throw new IOException("MediaStore insert failed");
        ParcelFileDescriptor pfd = cr.openFileDescriptor(uri, "rw");
        if (pfd == null) {
            cr.delete(uri, null, null);
            throw new IOException("no file descriptor");
        }
        FileChannel ch = new FileOutputStream(pfd.getFileDescriptor()).getChannel();
        return new Clip(uri, pfd, ch, name);
    }

    /** Closes the file; a clip with frames becomes visible, an empty one is removed. */
    void finish(Clip c, boolean keep) {
        try {
            c.channel.close();
        } catch (IOException ignored) {
        }
        try {
            c.pfd.close();
        } catch (IOException ignored) {
        }
        try {
            if (keep) {
                ContentValues v = new ContentValues();
                v.put(MediaStore.MediaColumns.IS_PENDING, 0);
                cr.update(c.uri, v, null, null);
            } else {
                cr.delete(c.uri, null, null);
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "finish " + c.name, e);
        }
    }

    /** After a power loss the clip that was being written is still pending: publish it (or drop it if empty). */
    void recoverPending() {
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
                MediaStore.MediaColumns.RELATIVE_PATH + "=?", new String[]{DIR},
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

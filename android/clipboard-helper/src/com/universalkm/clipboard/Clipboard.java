package com.universalkm.clipboard;

import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

import android.content.ClipData;
import android.os.Binder;
import android.os.IBinder;
import android.os.IInterface;
import android.os.Parcel;

/**
 * The hidden system clipboard service (IClipboard), reached through reflection as the shell user
 * (design D3). Method signatures changed between Android versions (attributionTag, userId, deviceId
 * were added), so each call fills the parameters it finds by type: the first String is our package,
 * later Strings are null (attribution tag), ints are 0 (user 0, default device).
 */
final class Clipboard {
    private static final String PACKAGE = "com.android.shell";
    private static final String LISTENER = "android.content.IOnPrimaryClipChangedListener";

    private final Object service;
    private final Method getPrimaryClip;
    private final Method setPrimaryClip;
    private final Method addListener;

    Clipboard() throws Exception {
        Class<?> serviceManager = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) serviceManager.getMethod("getService", String.class).invoke(null, "clipboard");
        if (binder == null) throw new IllegalStateException("no clipboard service");
        Class<?> stub = Class.forName("android.content.IClipboard$Stub");
        service = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
        getPrimaryClip = longest("getPrimaryClip");
        setPrimaryClip = longest("setPrimaryClip");
        addListener = longest("addPrimaryClipChangedListener");
        if (getPrimaryClip == null || setPrimaryClip == null) throw new NoSuchMethodException("IClipboard");
    }

    /** The overload with the most parameters is the one the running Android version implements. */
    private Method longest(String name) {
        Method best = null;
        for (Method m : service.getClass().getMethods()) {
            if (m.getName().equals(name) && (best == null || m.getParameterTypes().length > best.getParameterTypes().length)) {
                best = m;
            }
        }
        return best;
    }

    private static Object[] arguments(Method method, Object special) {
        Class<?>[] types = method.getParameterTypes();
        Object[] args = new Object[types.length];
        boolean packageGiven = false;
        for (int i = 0; i < types.length; i++) {
            Class<?> type = types[i];
            if (type == String.class) {
                args[i] = packageGiven ? null : PACKAGE;
                packageGiven = true;
            } else if (type == int.class) {
                args[i] = 0;
            } else if (type == boolean.class) {
                args[i] = false;
            } else if (special != null && type.isInstance(special)) {
                args[i] = special;
            } else {
                args[i] = null;
            }
        }
        return args;
    }

    /** Plain text of the first clip item, or null for an empty clipboard or a clip without text. */
    String getText() throws Exception {
        ClipData clip = (ClipData) getPrimaryClip.invoke(service, arguments(getPrimaryClip, null));
        if (clip == null || clip.getItemCount() == 0) return null;
        ClipData.Item item = clip.getItemAt(0);
        CharSequence text = item.getText();
        if (text == null) text = item.getHtmlText();
        return text == null ? null : text.toString();
    }

    void set(String text) throws Exception {
        ClipData clip = ClipData.newPlainText("UniversalKM", text);
        setPrimaryClip.invoke(service, arguments(setPrimaryClip, clip));
    }

    /**
     * Subscribes to clipboard changes. The listener interface is hidden, so a dynamic proxy implements
     * it and hands out our own Binder, whose transaction 1 is dispatchPrimaryClipChanged (oneway).
     * Returns false when the subscription is not possible; the caller polls instead.
     */
    boolean listen(Runnable onChange) {
        if (addListener == null) return false;
        try {
            Class<?> listenerType = Class.forName(LISTENER);
            Binder binder = new Binder() {
                @Override
                protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                    if (code == IBinder.FIRST_CALL_TRANSACTION) {
                        onChange.run();
                        return true;
                    }
                    return code == IBinder.INTERFACE_TRANSACTION;
                }
            };
            Object listener = Proxy.newProxyInstance(listenerType.getClassLoader(),
                    new Class<?>[] {listenerType},
                    (proxy, method, args) -> {
                        switch (method.getName()) {
                            case "asBinder": return binder;
                            case "hashCode": return System.identityHashCode(proxy);
                            case "equals": return proxy == args[0];
                            case "toString": return "UniversalKMClipListener";
                            default: return null;
                        }
                    });
            binder.attachInterface((IInterface) listener, LISTENER);
            addListener.invoke(service, arguments(addListener, listener));
            return true;
        } catch (Throwable e) {
            return false;
        }
    }
}

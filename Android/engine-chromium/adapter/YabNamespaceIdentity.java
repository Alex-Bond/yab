// Unapplied source scaffold for Chromium ac19329a1d32108fd05ead15568cb6e188f8615a.
package org.chromium.chrome.browser.tab;

import android.util.AtomicFile;

import org.chromium.build.annotations.NullMarked;
import org.chromium.build.annotations.Nullable;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Objects;
import java.util.UUID;

/** Native app identity. Never populated from a URL, page message, or JavaScript bridge. */
@NullMarked
public final class YabNamespaceIdentity {
    public final String accountId;
    public final String tabId;
    public final String namespaceId;
    public final boolean inMemory;
    public final boolean privateMode;

    public YabNamespaceIdentity(String accountId, String tabId, String namespaceId,
            boolean inMemory, boolean privateMode) {
        this.accountId = canonical(accountId);
        this.tabId = canonical(tabId);
        this.namespaceId = canonical(namespaceId);
        if (privateMode && !inMemory) throw new IllegalArgumentException("Private data must be transient");
        this.inMemory = inMemory;
        this.privateMode = privateMode;
    }

    private static String canonical(String value) {
        if (!UUID.fromString(value).toString().equals(value)) {
            throw new IllegalArgumentException("Identity must be a canonical lowercase UUID");
        }
        return value;
    }

    @Override
    public boolean equals(@Nullable Object other) {
        if (!(other instanceof YabNamespaceIdentity)) return false;
        YabNamespaceIdentity that = (YabNamespaceIdentity) other;
        return accountId.equals(that.accountId) && tabId.equals(that.tabId)
                && namespaceId.equals(that.namespaceId) && inMemory == that.inMemory
                && privateMode == that.privateMode;
    }

    @Override
    public int hashCode() {
        return Objects.hash(accountId, tabId, namespaceId, inMemory, privateMode);
    }

    /** One app-private AtomicFile per Chrome tab ID; no private-mode record is written. */
    static final class Store {
        private final File mDirectory;
        private final String mAccount;

        Store(File appFilesDirectory, String account) throws IOException {
            mAccount = canonical(account);
            mDirectory = new File(appFilesDirectory, "yab_namespace_identity/" + mAccount);
            if (!mDirectory.isDirectory() && !mDirectory.mkdirs()) {
                throw new IOException("Cannot create namespace identity directory");
            }
        }

        private AtomicFile file(int chromeId) {
            if (chromeId < 0) throw new IllegalArgumentException("Invalid Chrome tab ID");
            return new AtomicFile(new File(mDirectory, chromeId + ".json"));
        }

        void write(int chromeId, YabNamespaceIdentity identity, String digest) throws IOException {
            if (identity.privateMode || !mAccount.equals(identity.accountId)) {
                throw new IOException("Refused identity for another account or private mode");
            }
            AtomicFile destination = file(chromeId);
            FileOutputStream stream = null;
            try {
                JSONObject row = new JSONObject();
                row.put("format", 1);
                row.put("chromeId", chromeId);
                row.put("account", identity.accountId);
                row.put("tab", identity.tabId);
                row.put("namespace", identity.namespaceId);
                row.put("inMemory", identity.inMemory);
                row.put("private", false);
                row.put("stateSha256", digest);
                stream = destination.startWrite();
                stream.write(row.toString().getBytes(StandardCharsets.UTF_8));
                destination.finishWrite(stream);
            } catch (JSONException error) {
                if (stream != null) destination.failWrite(stream);
                throw new IOException("Cannot encode namespace identity", error);
            } catch (IOException error) {
                if (stream != null) destination.failWrite(stream);
                throw error;
            }
        }

        boolean matches(int chromeId, YabNamespaceIdentity expected, String digest) {
            if (expected.privateMode || !mAccount.equals(expected.accountId)) return false;
            try (FileInputStream stream = file(chromeId).openRead()) {
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                byte[] chunk = new byte[1024];
                int count;
                while ((count = stream.read(chunk)) != -1) {
                    if (bytes.size() + count > 4096) return false;
                    bytes.write(chunk, 0, count);
                }
                JSONObject row = new JSONObject(bytes.toString(StandardCharsets.UTF_8.name()));
                return row.getInt("format") == 1 && row.getInt("chromeId") == chromeId
                        && row.getString("account").equals(expected.accountId)
                        && row.getString("tab").equals(expected.tabId)
                        && row.getString("namespace").equals(expected.namespaceId)
                        && row.getBoolean("inMemory") == expected.inMemory
                        && !row.getBoolean("private")
                        && row.getString("stateSha256").equals(digest);
            } catch (IOException | JSONException | IllegalArgumentException error) {
                return false;
            }
        }

        void remove(int chromeId) {
            file(chromeId).delete();
        }
    }
}

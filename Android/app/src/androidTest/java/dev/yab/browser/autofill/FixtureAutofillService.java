package dev.yab.browser.autofill;

import android.app.assist.AssistStructure;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.Intent;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.service.autofill.AutofillService;
import android.service.autofill.Dataset;
import android.service.autofill.FillCallback;
import android.service.autofill.FillRequest;
import android.service.autofill.FillResponse;
import android.service.autofill.SaveCallback;
import android.service.autofill.SaveRequest;
import android.util.Log;
import android.util.Pair;
import android.view.autofill.AutofillId;
import android.view.autofill.AutofillValue;
import android.view.autofill.AutofillManager;
import android.widget.Button;
import android.widget.RemoteViews;
import java.net.URI;
import java.util.List;

/** Test APK only. No storage, network, real login data, compatibility mode or save UI. */
@SuppressWarnings("deprecation")
public final class FixtureAutofillService extends AutofillService {
    private static final String TAG = "YabAutofillFixture";

    @Override public void onFillRequest(FillRequest request, CancellationSignal cancellation, FillCallback callback) {
        if (cancellation.isCanceled() || request.getFillContexts().isEmpty()) { callback.onSuccess(null); return; }
        AssistStructure structure = request.getFillContexts().get(request.getFillContexts().size() - 1).getStructure();
        if (structure.getActivityComponent() == null || !"dev.yab.android.dev".equals(structure.getActivityComponent().getPackageName())) {
            callback.onSuccess(null); return;
        }
        Fields fields = new Fields();
        for (int i = 0; i < structure.getWindowNodeCount(); i++) visit(structure.getWindowNodeAt(i).getRootViewNode(), fields);
        // Only shape diagnostics from this owned fictional form, never values.
        Log.i(TAG, "Owned fixture request: username=" + (fields.username != null)
                + " password=" + (fields.password != null) + " nodes=" + fields.nodes
                + " htmlInput=" + fields.htmlInputs + " loopbackInput=" + fields.loopbackInputs
                + " namedInput=" + fields.namedInputs + " autocompleteInput=" + fields.autocompleteInputs
                + " classes=" + fields.classes
                + " matchingCase="
                + (fields.usernameCase != null && fields.usernameCase.equals(fields.passwordCase)));
        if (fields.username == null || fields.password == null || fields.usernameCase == null ||
                !fields.usernameCase.equals(fields.passwordCase) || cancellation.isCanceled()) {
            callback.onSuccess(null); return;
        }
        String fixture = fields.usernameCase;
        RemoteViews presentation = new RemoteViews(getPackageName(), android.R.layout.simple_list_item_1);
        presentation.setTextViewText(android.R.id.text1, "Yab fixture " + fixture);
        Dataset dataset = new Dataset.Builder(presentation).setId("yab-fixture-" + fixture)
                .setValue(fields.username, AutofillValue.forText("fixture-" + fixture))
                .setValue(fields.password, AutofillValue.forText("invented-password-" + fixture))
                .build();
        // Logs identify only a fixture case. Never read or log existing field values.
        Log.i(TAG, "Native FillRequest accepted for loopback fixture " + fixture);
        Dataset offered = dataset;
        if ("authenticated".equals(fixture)) {
            Intent intent = new Intent(this, AuthenticationActivity.class).putExtra("fixtureDataset", dataset);
            PendingIntent authenticate = PendingIntent.getActivity(this, 1, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
            offered = new Dataset.Builder(presentation).setId("yab-fixture-authenticated")
                    .setValue(fields.username, null).setValue(fields.password, null)
                    .setAuthentication(authenticate.getIntentSender()).build();
        }
        callback.onSuccess(new FillResponse.Builder().addDataset(offered).build());
    }

    /** Actual Android dataset-authentication return, containing fictional values only. */
    public static final class AuthenticationActivity extends Activity {
        @Override protected void onCreate(Bundle savedState) {
            super.onCreate(savedState);
            final Dataset dataset = getIntent().getParcelableExtra("fixtureDataset");
            if (dataset == null) { finish(); return; }
            Button button = new Button(this);
            button.setText("Use fixture credential");
            button.setOnClickListener(view -> {
                setResult(RESULT_OK, new Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset));
                finish();
            });
            setContentView(button);
        }
    }

    @Override public void onSaveRequest(SaveRequest request, SaveCallback callback) {
        // No SaveInfo is supplied, and even an unexpected save request stores nothing.
        callback.onSuccess();
    }

    private static final class Fields {
        int nodes, htmlInputs, loopbackInputs, namedInputs, autocompleteInputs;
        final java.util.Map<String, Integer> classes = new java.util.TreeMap<>();
        AutofillId username, password;
        String usernameCase, passwordCase;
    }

    private static void visit(AssistStructure.ViewNode node, Fields fields) {
        if (++fields.nodes > 2000) return;
        String className = node.getClassName();
        if (className != null && className.matches("[A-Za-z0-9_.$]{1,160}") && fields.classes.size() < 24)
            fields.classes.put(className, fields.classes.getOrDefault(className, 0) + 1);
        if (node.getHtmlInfo() != null && "input".equalsIgnoreCase(node.getHtmlInfo().getTag())) {
            fields.htmlInputs++;
            if (loopback(node.getWebDomain())) fields.loopbackInputs++;
            if (attribute(node.getHtmlInfo().getAttributes(), "name") != null) fields.namedInputs++;
            if (attribute(node.getHtmlInfo().getAttributes(), "autocomplete") != null) fields.autocompleteInputs++;
        }
        if (node.getAutofillId() != null && node.getHtmlInfo() != null && "input".equalsIgnoreCase(node.getHtmlInfo().getTag()) && loopback(node.getWebDomain())) {
            List<Pair<String, String>> attributes = node.getHtmlInfo().getAttributes();
            String fixture = attribute(attributes, "data-yab-fixture-case");
            String autocomplete = attribute(attributes, "autocomplete");
            String name = attribute(attributes, "name");
            if (fixture == null && name != null && name.matches("yab-fixture-[a-z]{1,16}-(username|password)")) {
                fixture = name.substring("yab-fixture-".length(), name.lastIndexOf('-'));
            }
            if (fixture != null && fixture.matches("[a-z]{1,16}")) {
                if ("username".equals(autocomplete)) { fields.username = node.getAutofillId(); fields.usernameCase = fixture; }
                if ("current-password".equals(autocomplete)) { fields.password = node.getAutofillId(); fields.passwordCase = fixture; }
            }
        }
        for (int i = 0; i < node.getChildCount(); i++) visit(node.getChildAt(i), fields);
    }

    private static String attribute(List<Pair<String, String>> attributes, String key) {
        if (attributes != null) for (Pair<String, String> attribute : attributes) if (key.equalsIgnoreCase(attribute.first)) return attribute.second;
        return null;
    }

    private static boolean loopback(String domain) {
        if (domain == null) return false;
        try { return "127.0.0.1".equals(URI.create(domain.contains("://") ? domain : "http://" + domain).getHost()); }
        catch (IllegalArgumentException ignored) { return false; }
    }
}

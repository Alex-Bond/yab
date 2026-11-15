package dev.yab.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Button

/** Tests only PendingIntent result ownership. This is never an authenticator or credential provider. */
class WebAuthnResultTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(Button(this).apply {
            text = "Return native activity result"
            setOnClickListener { setResult(RESULT_OK, Intent().putExtra("fixture", "owned-result")); finish() }
        })
    }
}

package xyz.hesn.rdmns_flutter

import android.os.Build
import android.os.Bundle
import android.view.View
import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity is required by local_auth (fingerprint / face unlock).
class MainActivity : FlutterFragmentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hideFromScreenReadingApps()
    }

    override fun onPostResume() {
        super.onPostResume()
        hideFromScreenReadingApps()
    }

    /**
     * Android 14+: apps that use accessibility only to read the screen (data scrapers,
     * spy apps, auto-clickers) receive no content or events from this window, including
     * the web pages. Real accessibility tools such as TalkBack, Select to Speak,
     * Switch Access and Voice Access (services declared isAccessibilityTool) keep working.
     */
    private fun hideFromScreenReadingApps() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            window.decorView.setAccessibilityDataSensitive(View.ACCESSIBILITY_DATA_SENSITIVE_YES)
        }
    }
}

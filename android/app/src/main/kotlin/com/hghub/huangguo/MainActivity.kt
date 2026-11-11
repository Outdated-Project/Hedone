package com.hghub.huangguo

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private val refreshPolicy by lazy { DisplayRefreshPolicy(this) }

    override fun onResume() {
        super.onResume()
        refreshPolicy.start()
    }

    override fun onPause() {
        refreshPolicy.stop()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        refreshPolicy.update()
    }
}

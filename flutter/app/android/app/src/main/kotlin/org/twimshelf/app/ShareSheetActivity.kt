package org.twimshelf.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

/**
 * The share page over the app that shared, in that app's task: a see-through window with only the
 * sheet in it (`shareSheetMain`). It never opens the library. What the person confirms goes to the
 * inbox, and the app imports it the next time it comes forward, as with the iOS extension.
 */
class ShareSheetActivity : FlutterActivity() {
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent
    override fun getDartEntrypointFunctionName(): String = "shareSheetMain"
    override fun getDartEntrypointArgs(): List<String> = listOfNotNull(intent.getStringExtra(EXTRA_ID), intent.getStringExtra(EXTRA_ROOT))

    companion object {
        const val EXTRA_ID = "id"
        const val EXTRA_ROOT = "root"
    }
}

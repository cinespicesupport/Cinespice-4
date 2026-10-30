package app.cinespice.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import androidx.compose.runtime.*
import kotlinx.coroutines.*
import java.io.File

class MainActivity : ComponentActivity() {
    internal val model: LibraryModel by viewModels()
    internal var opening by mutableStateOf<Video?>(null)
    private var openJob: Job? = null
    private var exportVideo: Video? = null
    private var exportGeneration = -1L
    private val export = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val video = exportVideo; exportVideo = null
        val session = exportGeneration; exportGeneration = -1L
        val uri = result.data?.data
        if (result.resultCode == RESULT_OK && uri != null && video != null) {
            if (model.busy) {
                model.message("Could not save while another operation is running. Please try again.")
                return@registerForActivityResult
            }
            model.work("Saving video…") {
                model.telegram.check(session)
                val path = model.telegram.completedPath(video)
                check(path.isNotEmpty()) { "The local file is no longer available. Download it again." }
                withContext(Dispatchers.IO) { File(path).inputStream().use { input -> contentResolver.openOutputStream(uri).use { output ->
                    checkNotNull(output) { "Could not open destination" }
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        model.telegram.check(session)
                        val count = input.read(buffer); if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                } }
                }
                model.message("Video saved")
            }
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        setContent { Cinespice(this, model) }
    }
    override fun onResume() { super.onResume(); model.foreground() }
    internal fun open(video: Video, resume: Boolean = true) {
        if (openJob?.isActive == true) return
        opening = video
        val generation = model.telegram.generation
        openJob = lifecycleScope.launch {
            try {
                val current = model.preparePlayback(video)
                model.telegram.check(generation)
                startActivity(Intent(this@MainActivity, PlayerActivity::class.java).putExtra("video", current.data.toString()).putExtra("resume", resume).putExtra("generation", generation))
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { model.message(e.message ?: "Could not open video") }
            finally { opening = null }
        }
    }
    internal fun cancelOpening() { openJob?.cancel(); opening = null }
    internal fun export(video: Video) {
        if (exportVideo != null) return
        exportVideo = video
        val generation = model.telegram.generation
        lifecycleScope.launch {
            try {
                val current = withContext(Dispatchers.IO) { model.telegram.prepare(video) }
                model.telegram.check(generation)
                check(model.telegram.completedPath(current).isNotEmpty()) { "Download this video first, then export it." }
                exportVideo = current; exportGeneration = generation
                export.launch(Intent(Intent.ACTION_CREATE_DOCUMENT).setType(current.mime).addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, File(current.name).name))
            } catch (e: Exception) { exportVideo = null; model.message(e.message ?: "Could not export video") }
        }
    }
    internal fun link(url: String) { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}

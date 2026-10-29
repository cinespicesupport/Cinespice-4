package app.cinespice.android

import android.net.Uri
import android.widget.TextView
import android.widget.VideoView
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.clickable
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable internal fun AccessActivation(model: LibraryModel) {
    val uri = androidx.compose.ui.platform.LocalUriHandler.current
    val config = model.telegram.access.config
    Column(Modifier.widthIn(max = 520.dp).fillMaxSize().verticalScroll(rememberScrollState()).padding(28.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("Activate your access", style = MaterialTheme.typography.headlineLarge)
        if (config == null) Text("Access setup is pending. Please contact the app owner for a configured build.")
        else {
            Text("Activate once on this device. Your membership keeps your access active.")
            Text(model.accessMessage)
            Button(onClick = { model.accessAction(true) }, enabled = !model.accessBusy) { Text(if (model.accessBusy) "Verifying…" else "Activate") }
            for (index in model.accessMissing.sorted().filter { it in 0 until config.channels.length() }) {
                val channel = config.channels.getJSONObject(index)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    OutlinedButton(onClick = { model.joinCommunity(channel.getString("url")) }, enabled = !model.accessBusy) { Text("Join ${channel.getString("title")}") }
                    TextButton(onClick = { uri.openUri(channel.getString("url")) }) { Text("Open") }
                }
            }
            if (model.accessNeedsPaid || model.accessRevoked) TextButton(onClick = { uri.openUri(config.contactURL) }) { Text(if (model.accessRevoked) "Contact support" else "Request paid-group access") }
        }
        if (model.status.isNotBlank()) Text(model.status)
        OutlinedButton(onClick = { model.signOut() }, enabled = !model.busy) { Text("Sign out") }
    }
}

@Composable internal fun AccessNotice(model: LibraryModel) {
    val notice = model.announcement ?: return
    var expanded by remember(notice.optLong("id")) { mutableStateOf(false) }
    Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).clickable(onClickLabel = "Read full announcement") { expanded = true }.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Announcement", style = MaterialTheme.typography.titleSmall)
                Text(Announcement.text(notice).toString().ifBlank { "New media from Cinespice" }, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                Text("Tap to read", style = MaterialTheme.typography.labelSmall)
            }
            TextButton(onClick = model::dismissAnnouncement) { Text("Dismiss") }
        }
    }
    if (expanded) NotificationDetail(model, notice, model::dismissAnnouncement)
}

@Composable internal fun NotificationHistory(model: LibraryModel) {
    var selected by remember { mutableStateOf<org.json.JSONObject?>(null) }
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(model.notifications) {
        if (selected != null && model.notifications.none { it.optLong("id") == selected?.optLong("id") }) selected = null
    }
    Dialog(onDismissRequest = model::closeNotifications, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.safeDrawingPadding().padding(20.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Notifications", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                    TextButton(onClick = { scope.launch { list.scrollToItem(0) } }, enabled = list.canScrollBackward) { Text("Top") }
                    TextButton(onClick = { model.loadNotifications(true) }, enabled = !model.notificationsLoading) { Text("Refresh") }
                    TextButton(onClick = model::closeNotifications) { Text("Close") }
                }
                LazyColumn(Modifier.weight(1f), state = list, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (model.notifications.isEmpty() && !model.notificationsLoading && model.notificationsError.isBlank()) item { Text("No notifications yet") }
                    items(model.notifications, key = { it.optLong("id") }) { notice ->
                        OutlinedCard(onClick = { selected = notice }, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(if (Announcement.hasMedia(notice)) "Media announcement" else "Announcement", style = MaterialTheme.typography.labelLarge)
                                Text(Announcement.text(notice).toString().ifBlank { "Photo or animation" }, maxLines = 3, overflow = TextOverflow.Ellipsis)
                                Text(java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(notice.optLong("date")*1000)), style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                    if (model.notificationsError.isNotBlank()) item { Column { Text(model.notificationsError); TextButton(onClick = { model.loadNotifications(true) }) { Text("Retry notifications") } } }
                    if (model.notificationsLoading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    else if (model.notificationsMore) item { TextButton(onClick = { model.loadNotifications(false) }) { Text("Load older notifications") } }
                }
            }
        }
    }
    selected?.let { notice -> NotificationDetail(model, notice) { selected = null } }
}

@Composable private fun NotificationDetail(model: LibraryModel, notice: org.json.JSONObject, close: () -> Unit) {
    var path by remember(notice.optLong("id")) { mutableStateOf<String?>(null) }
    var loading by remember(notice.optLong("id")) { mutableStateOf(false) }
    var retry by remember { mutableIntStateOf(0) }
    LaunchedEffect(notice.optLong("id"), retry) {
        if (Announcement.hasMedia(notice)) {
            loading = true; path = null
            path = withContext(Dispatchers.IO) {
                val local = model.telegram.access.media(notice)
                val animation = Json.child(Json.child(notice, "content"), "animation")
                val video = Announcement.animated(notice) && animation.optString("mime_type").startsWith("video/")
                if (local != null && !video) {
                    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeFile(local, bounds)
                    if (bounds.outWidth > 0 && bounds.outHeight > 0) local else null
                } else local
            }
            loading = false
        }
    }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.safeDrawingPadding().padding(20.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("From Cinespice", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                    TextButton(onClick = close) { Text("Close") }
                }
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    if (Announcement.hasMedia(notice)) BoxWithConstraints(Modifier.fillMaxWidth()) {
                        val mediaHeight = (maxWidth / Announcement.ratio(notice)).coerceIn(120.dp, 420.dp)
                        val local = path
                        if (local != null) {
                            val content = Json.child(notice, "content")
                            val video = Announcement.animated(notice) && Json.child(content, "animation").optString("mime_type").startsWith("video/")
                            if (video) AndroidView(factory = { context -> VideoView(context).apply { setVideoURI(Uri.fromFile(java.io.File(local))); setOnPreparedListener { it.isLooping = true; it.setVolume(0f,0f); start() }; setOnErrorListener { _, _, _ -> path = null; true } } }, modifier = Modifier.fillMaxWidth().height(mediaHeight), onRelease = { it.stopPlayback() })
                            else AndroidView(factory = { context -> AnnouncementImage(context, local) }, modifier = Modifier.fillMaxWidth().height(mediaHeight))
                        } else Column(Modifier.fillMaxWidth().height(mediaHeight), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                            if (loading) CircularProgressIndicator()
                            else { Text("Media could not be loaded."); TextButton(onClick = { retry++ }) { Text("Retry") } }
                        }
                    }
                    if (Announcement.text(notice).isNotEmpty()) {
                        val textColor = MaterialTheme.colorScheme.onSurface
                        AndroidView(factory = { context -> TextView(context).apply { textSize = 16f; setTextIsSelectable(true); movementMethod = android.text.method.LinkMovementMethod.getInstance() } }, modifier = Modifier.fillMaxWidth(), update = { it.text = Announcement.text(notice); it.setTextColor(android.graphics.Color.argb((textColor.alpha*255).toInt(),(textColor.red*255).toInt(),(textColor.green*255).toInt(),(textColor.blue*255).toInt())) })
                    }
                }
            }
        }
    }
}

/** Animated GIF and still preview without a network image loader or embedded bot credentials. */
private class AnnouncementImage @JvmOverloads constructor(context: android.content.Context, path: String = "") : android.view.View(context) {
    private val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true; android.graphics.BitmapFactory.decodeFile(path, this) }
    private val movie = if (bounds.outWidth.toLong() * bounds.outHeight in 1..2_500_000L) android.graphics.Movie.decodeFile(path) else null
    private val bitmap = if (movie == null) android.graphics.BitmapFactory.decodeFile(path, android.graphics.BitmapFactory.Options().apply {
        inSampleSize = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / inSampleSize > 1600) inSampleSize *= 2
    }) else null
    private val started = android.os.SystemClock.uptimeMillis()
    init { setLayerType(LAYER_TYPE_SOFTWARE, null) }
    override fun onDraw(canvas: android.graphics.Canvas) {
        super.onDraw(canvas)
        val w = movie?.width() ?: bitmap?.width ?: return
        val h = movie?.height() ?: bitmap?.height ?: return
        if (w <= 0 || h <= 0) return
        val scale = minOf(width.toFloat()/w,height.toFloat()/h)
        val saved = canvas.save(); canvas.translate((width-w*scale)/2,(height-h*scale)/2); canvas.scale(scale,scale)
        if (movie != null) { movie.setTime(((android.os.SystemClock.uptimeMillis()-started) % (movie.duration().takeIf { it > 0 } ?: 1000)).toInt()); movie.draw(canvas,0f,0f); postInvalidateDelayed(32) }
        else bitmap?.let { canvas.drawBitmap(it,0f,0f,null) }
        canvas.restoreToCount(saved)
    }
}

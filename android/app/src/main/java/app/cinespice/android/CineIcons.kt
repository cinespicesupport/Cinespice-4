package app.cinespice.android

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp

/** Small Material-style vectors; no full icon-catalogue dependency in the APK. */
internal object CineIcons {
    private fun icon(name: String, data: String) = ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).addPath(PathParser().parsePathString(data).toNodes(), fill = SolidColor(Color.Black)).build()
    val Download = icon("Download", "M19,9H15V3H9V9H5L12,16ZM5,18V20H19V18Z")
    val History = icon("History", "M13,3C8,3 4,7 4,12H1L5,16L9,12H6C6,8.1 9.1,5 13,5S20,8.1 20,12S16.9,19 13,19C10.9,19 9,18.1 7.7,16.7L6.3,18.1C8,19.9 10.3,21 13,21C18,21 22,17 22,12S18,3 13,3ZM12,7V13L17,16L18,14.4L14,12V7Z")
    val VideoLibrary = icon("VideoLibrary", "M4,6H2V20C2,21.1 2.9,22 4,22H18V20H4ZM20,2H8C6.9,2 6,2.9 6,4V16C6,17.1 6.9,18 8,18H20C21.1,18 22,17.1 22,16V4C22,2.9 21.1,2 20,2ZM12,6L18,10L12,14Z")
    val PersonOutline = icon("Profile", "M12,4C9.8,4 8,5.8 8,8S9.8,12 12,12S16,10.2 16,8S14.2,4 12,4ZM12,6C13.1,6 14,6.9 14,8S13.1,10 12,10S10,9.1 10,8S10.9,6 12,6ZM12,14C9.3,14 4,15.3 4,18V20H20V18C20,15.3 14.7,14 12,14ZM6,18C6,17.3 9.1,16 12,16S18,17.3 18,18Z")
    val Sort = icon("Sort", "M3,6H21V8H3ZM3,11H15V13H3ZM3,16H9V18H3Z")
    val Movie = icon("Movie", "M18,4L20,8H17L15,4H12L14,8H11L9,4H6L8,8H5L3,4H2V20H22V4ZM4,10H20V18H4Z")
    val LocalMovies = Movie
    val PlayCircleOutline = icon("Play", "M12,2C6.5,2 2,6.5 2,12S6.5,22 12,22S22,17.5 22,12S17.5,2 12,2ZM12,4C16.4,4 20,7.6 20,12S16.4,20 12,20S4,16.4 4,12S7.6,4 12,4ZM10,7V17L17,12Z")
    val Bookmark = icon("Bookmark", "M6,3H18V21L12,17L6,21Z")
    val ChevronRight = icon("Browse", "M9,6L7.6,7.4L12.2,12L7.6,16.6L9,18L15,12Z")
    val CameraAlt = icon("Camera", "M9,3L7,6H3C1.9,6 1,6.9 1,8V20H23V8C23,6.9 22.1,6 21,6H17L15,3ZM12,8C15.3,8 18,10.7 18,14S15.3,20 12,20S6,17.3 6,14S8.7,8 12,8ZM12,10C9.8,10 8,11.8 8,14S9.8,18 12,18S16,16.2 16,14S14.2,10 12,10Z")
}

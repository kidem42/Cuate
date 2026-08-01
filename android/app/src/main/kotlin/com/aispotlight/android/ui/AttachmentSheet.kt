package com.aispotlight.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.aispotlight.android.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The composer's attachment sheet — one entry point for everything you can
 * hang on a message (the Telegram anatomy): a grid of the device's recent
 * photos with the camera as its first tile, plus rows for the system photo
 * picker and for ANY file.
 *
 * Selection is multi-tap: tiles carry an order badge and the confirm button
 * attaches the whole set at once. Without the photos permission the grid is
 * replaced by a single "allow" row — the camera and the system picker (which
 * needs no permission of its own) keep working, so the sheet is never a dead
 * end.
 */
/** Photos one tap-through of the grid may stage at once. */
private const val MAX_SELECTION = 10

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AttachmentSheet(
    onAttachImages: (List<Uri>) -> Unit,
    onCamera: () -> Unit,
    onAttachFile: (Uri) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selected by remember { mutableStateOf<List<Uri>>(emptyList()) }
    var images by remember { mutableStateOf<List<Uri>>(emptyList()) }
    var permissionGranted by remember { mutableStateOf(hasPhotosPermission(context)) }

    // The grid reads MediaStore directly; a granted permission (or a partial
    // 34+ grant, which simply narrows the query) refills it in place.
    LaunchedEffect(permissionGranted) {
        images = if (permissionGranted) {
            withContext(Dispatchers.IO) { recentImages(context) }
        } else {
            emptyList()
        }
    }

    val photosPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissionGranted = hasPhotosPermission(context) }

    // The system Photo Picker: no permission, and on 34+ it is also the way
    // back to "select more photos" after a partial grant.
    val systemPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(maxItems = 8)
    ) { uris ->
        if (uris.isNotEmpty()) {
            onAttachImages(uris)
            onDismiss()
        }
    }

    // ANY file (documents, archives, audio…) through SAF.
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) {
            for (uri in uris) {
                // Persist nothing: the import copies the bytes right away.
                if (context.contentResolver.getType(uri)?.startsWith("image/") == true) {
                    onAttachImages(listOf(uri))
                } else {
                    onAttachFile(uri)
                }
            }
            onDismiss()
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(Modifier.navigationBarsPadding()) {
            if (permissionGranted) {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 320.dp)
                        .padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    item(key = "camera") { CameraTile(onClick = onCamera) }
                    items(images, key = { it.toString() }) { uri ->
                        val index = selected.indexOf(uri)
                        GalleryTile(
                            uri = uri,
                            selectionNumber = if (index >= 0) index + 1 else null,
                            onClick = {
                                selected = when {
                                    index >= 0 -> selected - uri
                                    // One message carries a handful of photos,
                                    // not an album: past the cap the taps stop
                                    // adding rather than quietly building a
                                    // 40-image upload.
                                    selected.size >= MAX_SELECTION -> selected
                                    else -> selected + uri
                                }
                            },
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
            } else {
                // No photos permission: the camera keeps its tile-sized slot,
                // and the "allow" row explains what the grid would show.
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(88.dp)) { CameraTile(onClick = onCamera) }
                    TextButton(onClick = { photosPermission.launch(photosPermissions()) }) {
                        Text(stringResource(R.string.attach_allow_photos))
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            SheetRow(
                icon = Icons.Filled.PhotoLibrary,
                label = stringResource(R.string.attach_gallery),
                onClick = {
                    systemPicker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                    )
                },
            )
            SheetRow(
                icon = Icons.Filled.AttachFile,
                label = stringResource(R.string.attach_any_file),
                onClick = { filePicker.launch(arrayOf("*/*")) },
            )

            if (selected.isNotEmpty()) {
                Button(
                    onClick = {
                        onAttachImages(selected)
                        onDismiss()
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    Text(stringResource(R.string.attach_confirm, selected.size))
                }
            } else {
                Spacer(Modifier.height(10.dp))
            }
        }
    }
}

@Composable
private fun SheetRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(16.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}

/** First cell of the grid: opens the system camera (the Telegram tile). */
@Composable
private fun CameraTile(onClick: () -> Unit) {
    Box(
        Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                Icons.Filled.PhotoCamera,
                contentDescription = stringResource(R.string.chat_camera),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(28.dp),
            )
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.chat_camera),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun GalleryTile(uri: Uri, selectionNumber: Int?, onClick: () -> Unit) {
    val context = LocalContext.current
    var bitmap by remember(uri) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(uri) {
        bitmap = withContext(Dispatchers.IO) { thumbnail(context, uri) }
    }
    Box(
        Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick),
    ) {
        bitmap?.let {
            Image(
                it.asImageBitmap(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxWidth().aspectRatio(1f),
            )
        }
        if (selectionNumber != null) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .border(
                        3.dp,
                        MaterialTheme.colorScheme.primary,
                        RoundedCornerShape(6.dp),
                    )
            )
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(4.dp)
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary),
                contentAlignment = Alignment.Center,
            ) {
                if (selectionNumber == 1) {
                    Icon(
                        Icons.Filled.Check,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(14.dp),
                    )
                } else {
                    Text(
                        "$selectionNumber",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                }
            }
        }
    }
}

/** Permissions the in-app grid needs — 33+ splits media out of storage. */
private fun photosPermissions(): Array<String> = when {
    android.os.Build.VERSION.SDK_INT >= 34 -> arrayOf(
        android.Manifest.permission.READ_MEDIA_IMAGES,
        android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
    )
    android.os.Build.VERSION.SDK_INT >= 33 ->
        arrayOf(android.Manifest.permission.READ_MEDIA_IMAGES)
    else -> arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
}

/**
 * True when the grid can read something. A 34+ PARTIAL grant
 * (READ_MEDIA_VISUAL_USER_SELECTED alone) counts: MediaStore then returns
 * exactly the photos the user shared, which is a perfectly good grid.
 */
private fun hasPhotosPermission(context: Context): Boolean =
    photosPermissions().any {
        androidx.core.content.ContextCompat.checkSelfPermission(context, it) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

/** Newest images from MediaStore (ids resolved to content Uris). */
private fun recentImages(context: Context, limit: Int = 90): List<Uri> {
    val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    val projection = arrayOf(MediaStore.Images.Media._ID)
    return try {
        context.contentResolver.query(
            collection, projection, null, null,
            "${MediaStore.Images.Media.DATE_MODIFIED} DESC",
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            buildList {
                while (cursor.moveToNext() && size < limit) {
                    add(android.content.ContentUris.withAppendedId(collection, cursor.getLong(idColumn)))
                }
            }
        } ?: emptyList()
    } catch (_: Exception) {
        emptyList()
    }
}

/** Square-ish thumbnail for a grid tile. */
private fun thumbnail(context: Context, uri: Uri, px: Int = 256): Bitmap? = try {
    if (android.os.Build.VERSION.SDK_INT >= 29) {
        context.contentResolver.loadThumbnail(uri, Size(px, px), null)
    } else {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= px) sample *= 2
        context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        }
    }
} catch (_: Exception) {
    null
}

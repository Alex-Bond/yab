package dev.yab.agent

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun ApprovalPaymentEditor(payment: ApprovalPayment, picks: ApprovalPicks, declinedCard: String? = null, enabled: Boolean = true,
    controlOwner: Any? = null, canEdit: () -> Boolean = { true }, onChange: (ApprovalPicks) -> Unit) {
    var addingCard by remember(payment) { mutableStateOf(picks.newCard != null) }
    var addingPlace by remember(payment) { mutableStateOf(picks.newPlace != null) }
    var number by remember(payment) { mutableStateOf(picks.newCard?.number.orEmpty()) }
    var expiration by remember(payment) { mutableStateOf(picks.newCard?.let { "${it.month}/${it.year}" }.orEmpty()) }
    var csc by remember(payment) { mutableStateOf(picks.newCard?.csc.orEmpty()) }
    var cardName by remember(payment) { mutableStateOf(picks.newCard?.name.orEmpty()) }
    var name by remember(payment) { mutableStateOf(picks.newPlace?.name.orEmpty()) }
    var street by remember(payment) { mutableStateOf(picks.newPlace?.street.orEmpty()) }
    var city by remember(payment) { mutableStateOf(picks.newPlace?.city.orEmpty()) }
    var postal by remember(payment) { mutableStateOf(picks.newPlace?.postal.orEmpty()) }
    val localOwner = remember(payment) { Any() }
    key(controlOwner ?: localOwner, enabled) {
        val control = remember { ApprovalPaymentControl(enabled) }
        DisposableEffect(control) { onDispose { control.dispose() } }
        fun editable() = control.current(canEdit)
        fun updateCard() {
            if (!editable()) return
            val parts = expiration.split('/').map { it.trim().toIntOrNull() ?: 0 }
            val year = parts.getOrElse(1) { 0 }.let { if (it in 1..99) 2000 + it else it }
            onChange(picks.copy(card = null, newCard = ApprovalNewCard(number.filter(Char::isDigit), csc, cardName, parts.firstOrNull() ?: 0, year)))
        }
        fun updatePlace() { if (editable()) onChange(picks.copy(place = null, newPlace = ApprovalNewPlace(name, street, city, postal))) }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp)) {
                Text(payment.site)
                Text(payment.item)
                Text(payment.amount, style = MaterialTheme.typography.headlineSmall)
                if (payment.delivery.isNotBlank()) Text(payment.delivery)
                payment.facts.forEach { Text(it) }
                if (!payment.takesCard) payment.cards.firstOrNull { it.id == payment.card }?.let { Text("${it.brand} ···· ${it.last4} · ${it.name}") }
                for (card in payment.cards.filter { payment.takesCard }) FilterChip(selected = picks.card == card.id && picks.newCard == null, enabled = enabled,
                    onClick = { if (editable()) { addingCard = false; onChange(picks.copy(card = card.id, newCard = null)) } },
                    label = { Text("${card.brand} ···· ${card.last4} · ${card.name}" + if (card.id == declinedCard) " · Declined by ${payment.site}" else "") })
                if (payment.takesCard) key(addingCard) {
                    val originalAdding = addingCard
                    val toggleControl = remember { ApprovalPaymentControl(enabled) }
                    DisposableEffect(toggleControl) { onDispose { toggleControl.dispose() } }
                    TextButton(enabled = enabled, onClick = { if (toggleControl.current { editable() && addingCard == originalAdding }) {
                        addingCard = !addingCard; if (addingCard) updateCard() else onChange(picks.copy(newCard = null))
                    } }) { Text(if (addingCard) "Cancel new card" else "Use a new card") }
                }
                if (addingCard) {
                    val cardControl = remember { ApprovalPaymentControl(enabled) }
                    DisposableEffect(cardControl) { onDispose { cardControl.dispose() } }
                    OutlinedTextField(number, { if (cardControl.current { editable() && addingCard }) { number = it; updateCard() } }, enabled = enabled, label = { Text("Card number") }, singleLine = true)
                    OutlinedTextField(expiration, { if (cardControl.current { editable() && addingCard }) { expiration = it; updateCard() } }, enabled = enabled, label = { Text("MM/YY") }, singleLine = true)
                    OutlinedTextField(csc, { if (cardControl.current { editable() && addingCard }) { csc = it; updateCard() } }, enabled = enabled, label = { Text("Security code") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
                    OutlinedTextField(cardName, { if (cardControl.current { editable() && addingCard }) { cardName = it; updateCard() } }, enabled = enabled, label = { Text("Name on card") }, singleLine = true)
                }
                if (!payment.takesPlace) payment.places.firstOrNull { it.id == payment.place }?.let { Text("${it.who} · ${it.line}") }
                for (place in payment.places.filter { payment.takesPlace }) FilterChip(selected = picks.place == place.id && picks.newPlace == null, enabled = enabled,
                    onClick = { if (editable()) { addingPlace = false; onChange(picks.copy(place = place.id, newPlace = null)) } }, label = { Text("${place.who} · ${place.line}") })
                if (payment.takesPlace) key(addingPlace) {
                    val originalAdding = addingPlace
                    val toggleControl = remember { ApprovalPaymentControl(enabled) }
                    DisposableEffect(toggleControl) { onDispose { toggleControl.dispose() } }
                    TextButton(enabled = enabled, onClick = { if (toggleControl.current { editable() && addingPlace == originalAdding }) {
                        addingPlace = !addingPlace; if (addingPlace) updatePlace() else onChange(picks.copy(newPlace = null))
                    } }) { Text(if (addingPlace) "Cancel new address" else "Use a new address") }
                }
                if (addingPlace) {
                    val placeControl = remember { ApprovalPaymentControl(enabled) }
                    DisposableEffect(placeControl) { onDispose { placeControl.dispose() } }
                    OutlinedTextField(name, { if (placeControl.current { editable() && addingPlace }) { name = it; updatePlace() } }, enabled = enabled, label = { Text("Name") }, singleLine = true)
                    OutlinedTextField(street, { if (placeControl.current { editable() && addingPlace }) { street = it; updatePlace() } }, enabled = enabled, label = { Text("Street") })
                    OutlinedTextField(city, { if (placeControl.current { editable() && addingPlace }) { city = it; updatePlace() } }, enabled = enabled, label = { Text("City") }, singleLine = true)
                    OutlinedTextField(postal, { if (placeControl.current { editable() && addingPlace }) { postal = it; updatePlace() } }, enabled = enabled, label = { Text("Postal code") }, singleLine = true)
                }
            }
        }
    }
}

/** Actual input nodes retain one rendered owner even when their callbacks are saved. */
private class ApprovalPaymentControl(private val enabled: Boolean) {
    private var disposed = false
    fun dispose() { disposed = true }
    fun current(canEdit: () -> Boolean): Boolean = !disposed && enabled && canEdit() && !disposed
}

@Composable
fun ApprovalFilePreview(file: ApprovalFile, previews: List<ApprovalPreview>,
    previewModifier: @Composable (ApprovalPreview) -> Modifier = { Modifier }, onPreview: ((ApprovalPreview) -> Unit)? = null,
    enabled: Boolean = true, canInteract: () -> Boolean = { true }) {
    var expanded by remember(file.id) { mutableStateOf(false) }
    Column(Modifier.padding(vertical = 6.dp)) {
        TextButton(enabled = enabled, onClick = { if (enabled && canInteract()) expanded = !expanded }) { Text("${file.name} · ${file.size / 1000} KB" + if (file.pages > 0) " · ${file.pages} pages" else if (file.previewPages > 0) " · ${file.previewPages} preview pages" else "") }
        if (expanded) {
            val pages = previews.filter { it.file == file.id }.sortedBy { it.page }
            if (pages.isEmpty()) Text("Preview has not arrived from your Mac")
            for (preview in pages) {
                val image = approvalPreviewBitmap(preview)
                image?.let { Image(it.asImageBitmap(), contentDescription = "${file.name}, page ${preview.page + 1}",
                    modifier = previewModifier(preview).fillMaxWidth().then(if (onPreview != null) Modifier.clickable(enabled = enabled) { if (enabled && canInteract()) onPreview(preview) } else Modifier)) }
            }
        }
    }
}

/** Uses only the bounded decrypted preview from this request. No file URL or network fetch. */
@Composable
internal fun approvalPreviewBitmap(preview: ApprovalPreview?, maxDimension: Int = 2048): Bitmap? {
    require(maxDimension in 64..2048)
    return androidx.compose.runtime.key(preview, maxDimension) {
        val image by produceState<Bitmap?>(null, preview) {
            if (preview == null) return@produceState
            value = withContext(Dispatchers.Default) {
                try {
                    if (preview.jpegBase64.length > 8 * 1024 * 1024) return@withContext null
                    val bytes = Base64.decode(preview.jpegBase64, Base64.DEFAULT)
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                    if (bounds.outWidth !in 1..4096 || bounds.outHeight !in 1..4096) null
                    else {
                        val decode = BitmapFactory.Options().apply { inSampleSize = 1 }
                        while (maxOf(bounds.outWidth, bounds.outHeight) / decode.inSampleSize.coerceAtLeast(1) > maxDimension)
                            decode.inSampleSize = decode.inSampleSize.coerceAtLeast(1) * 2
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decode)
                    }
                } catch (_: Exception) { null }
            }
        }
        image
    }
}

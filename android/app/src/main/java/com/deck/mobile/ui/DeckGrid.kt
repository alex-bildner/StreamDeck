package com.deck.mobile.ui

import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.deck.mobile.model.DeckSlot
import kotlin.math.min
import kotlin.math.roundToInt

private class GridMetrics {
    var cols: Int = 5
    var count: Int = 10
    var cell: Float = 1f
    var gap: Float = 0f
    var originX: Float = 0f
    var originY: Float = 0f

    fun positionOf(index: Int): Offset {
        val stride = cell + gap
        val col = index % cols
        val row = index / cols
        return Offset(originX + col * stride, originY + row * stride)
    }

    fun indexAt(topLeft: Offset): Int {
        val stride = cell + gap
        if (stride <= 0f) return 0
        val centerX = topLeft.x + cell / 2f
        val centerY = topLeft.y + cell / 2f
        val rows = (count + cols - 1) / cols
        val col = ((centerX - originX) / stride).toInt().coerceIn(0, cols - 1)
        val row = ((centerY - originY) / stride).toInt().coerceIn(0, rows - 1)
        return (row * cols + col).coerceIn(0, count - 1)
    }
}

private class DragState {
    var index by mutableIntStateOf(-1)
    var offset by mutableStateOf(Offset.Zero)
}

class PageSwipeGate {
    var claimPage: Boolean = false
    var page: Int = 0
    var pageCount: Int = 3
    var originPage: Int = 0
    var committed: Boolean = false
    var onClaim: () -> Unit = {}
    var onDrag: (Float) -> Unit = {}
    var onRelease: () -> Unit = {}
    var velocityX = 0f
    var pageWidth = 1f
    var pagerCoordinates: androidx.compose.ui.layout.LayoutCoordinates? = null
    var calendarCoordinates: androidx.compose.ui.layout.LayoutCoordinates? = null

    fun coversCalendar(localOnPager: androidx.compose.ui.geometry.Offset): Boolean {
        val pager = pagerCoordinates ?: return false
        val calendar = calendarCoordinates ?: return false
        if (!pager.isAttached || !calendar.isAttached) return false
        val root = pager.localToRoot(localOnPager)
        return calendar.boundsInRoot().contains(root)
    }
}

@Composable
fun DeckGrid(
    slots: List<DeckSlot>,
    iconFor: (String) -> ImageBitmap?,
    onMove: (Int, Int) -> Unit,
    onLaunch: (Int) -> Unit,
    onLink: (Int) -> Unit,
    onDragFinished: () -> Unit,
    pageSwipe: PageSwipeGate,
    customIcon: (String) -> ImageBitmap? = { null },
    editingIcons: Boolean = false,
    onEditIcon: (Int) -> Unit = {},
    addDescription: String = "Vincular aplicativo",
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val dragState = remember { DragState() }
    val metrics = remember { GridMetrics() }
    val moveState = rememberUpdatedState(onMove)
    val launchState = rememberUpdatedState(onLaunch)
    val linkState = rememberUpdatedState(onLink)
    val finishState = rememberUpdatedState(onDragFinished)
    val editState = rememberUpdatedState(onEditIcon)

    BoxWithConstraints(modifier.fillMaxSize()) {
        val landscape = maxWidth > maxHeight
        val cols = if (landscape) 5 else 2
        val gapPx = with(density) { 10.dp.toPx() }
        val availW = constraints.maxWidth.toFloat()
        val availH = constraints.maxHeight.toFloat()
        if (availW <= 0f || availH <= 0f) return@BoxWithConstraints
        val cellPx = min(
            (availW - gapPx * (cols - 1)) / cols,
            (availH - gapPx * ((slots.size + cols - 1) / cols - 1).coerceAtLeast(0)) / ((slots.size + cols - 1) / cols).coerceAtLeast(1),
        ).coerceAtLeast(1f)
        val rows = (slots.size + cols - 1) / cols
        val gridW = cols * cellPx + (cols - 1) * gapPx
        val gridH = rows * cellPx + (rows - 1).coerceAtLeast(0) * gapPx
        metrics.cols = cols
        metrics.count = slots.size
        metrics.cell = cellPx
        metrics.gap = gapPx
        metrics.originX = (availW - gridW) / 2f
        metrics.originY = (availH - gridH) / 2f
        val cellDp = with(density) { cellPx.toDp() }
        val radius = cellDp * 0.16f

        slots.forEachIndexed { index, slot ->
            androidx.compose.runtime.key(slot.key) {
                DeckKey(
                    slot = slot,
                    index = index,
                    target = metrics.positionOf(index),
                    cell = cellDp,
                    radius = radius,
                    bitmap = customIcon(slot.key) ?: slot.app?.let { iconFor(it.id) },
                    editingIcons = editingIcons,
                    dragging = dragState.index == index,
                    dragOffset = if (dragState.index == index) dragState.offset else Offset.Zero,
                    metrics = metrics,
                    dragState = dragState,
                    onMove = { from, to -> moveState.value(from, to) },
                    onLaunch = { launchState.value(it) },
                    onLink = { linkState.value(it) },
                    onDragFinished = { finishState.value() },
                    onEditIcon = { editState.value(it) },
                    pageSwipe = pageSwipe,
                    addDescription = addDescription,
                )
            }
        }
    }
}

@Composable
private fun DeckKey(
    slot: DeckSlot,
    index: Int,
    target: Offset,
    cell: Dp,
    radius: Dp,
    bitmap: ImageBitmap?,
    dragging: Boolean,
    dragOffset: Offset,
    metrics: GridMetrics,
    dragState: DragState,
    onMove: (Int, Int) -> Unit,
    onLaunch: (Int) -> Unit,
    onLink: (Int) -> Unit,
    onDragFinished: () -> Unit,
    onEditIcon: (Int) -> Unit,
    pageSwipe: PageSwipeGate,
    editingIcons: Boolean,
    addDescription: String,
) {
    val indexState = rememberUpdatedState(index)
    val slotState = rememberUpdatedState(slot)
    val moveState = rememberUpdatedState(onMove)
    val launchState = rememberUpdatedState(onLaunch)
    val linkState = rememberUpdatedState(onLink)
    val finishState = rememberUpdatedState(onDragFinished)
    val editState = rememberUpdatedState(onEditIcon)
    val editingState = rememberUpdatedState(editingIcons)
    val view = LocalView.current
    var pressed by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = when {
            dragging -> 1.06f
            pressed -> 0.94f
            else -> 1f
        },
        animationSpec = spring(stiffness = Spring.StiffnessMedium),
        label = "key-scale",
    )
    val shape = RoundedCornerShape(radius)
    val visual = if (dragging) target + dragOffset else target
    val app = slot.app

    Box(
        modifier = Modifier
            .offset { IntOffset(visual.x.roundToInt(), visual.y.roundToInt()) }
            .zIndex(if (dragging) 1f else 0f)
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                shadowElevation = if (dragging) 28f else 0f
                this.shape = shape
                clip = false
            }
            .size(cell)
            .pointerInput(slot.key) {
                val slop = viewConfiguration.touchSlop * 2f
                val holdMillis = 700L
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = true)
                    down.consume()
                    pressed = true
                    var dragStarted = false
                    var paging = false
                    var released = false
                    try {
                        val waited = withTimeoutOrNull(holdMillis) {
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                if (pageSwipe.claimPage) {
                                    paging = true
                                    break
                                }
                                if (!change.pressed) {
                                    released = true
                                    change.consume()
                                    break
                                }
                                if ((change.position - down.position).getDistance() > slop) break
                            }
                        }
                        val heldStill = waited == null && !paging && !released
                        if (heldStill) {
                            dragStarted = true
                            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            dragState.index = indexState.value
                            dragState.offset = Offset.Zero
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                if (pageSwipe.claimPage) {
                                    paging = true
                                    dragState.index = -1
                                    dragState.offset = Offset.Zero
                                    break
                                }
                                if (!change.pressed) {
                                    change.consume()
                                    break
                                }
                                val delta = change.position - change.previousPosition
                                change.consume()
                                if (delta != Offset.Zero) {
                                    dragState.offset += delta
                                    val current = dragState.index
                                    if (current >= 0) {
                                        val targetIndex = metrics.indexAt(metrics.positionOf(current) + dragState.offset)
                                        if (targetIndex != current) {
                                            val oldPos = metrics.positionOf(current)
                                            moveState.value(current, targetIndex)
                                            dragState.offset += oldPos - metrics.positionOf(targetIndex)
                                            dragState.index = targetIndex
                                        }
                                    }
                                }
                            }
                        } else if (released && !paging) {
                            view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
                            val current = indexState.value
                            if (editingState.value) editState.value(current)
                            else if (slotState.value.app != null) launchState.value(current)
                            else linkState.value(current)
                        } else if (!released) {
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                if (pageSwipe.claimPage) paging = true
                                if (!change.pressed) break
                            }
                        }
                    } finally {
                        pressed = false
                        if (dragStarted && !paging) {
                            dragState.index = -1
                            dragState.offset = Offset.Zero
                            finishState.value()
                        } else {
                            dragState.index = -1
                            dragState.offset = Offset.Zero
                        }
                    }
                }
            }
            .clip(shape)
            .background(DeckPalette.Key)
            .border(
                1.dp,
                Color.White.copy(
                    alpha = when {
                        editingIcons -> 0.42f
                        dragging -> 0.28f
                        else -> 0.08f
                    },
                ),
                shape,
            ),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(start = 8.dp, end = 8.dp, top = 8.dp, bottom = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            BoxWithConstraints(
                Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                val side = if (maxWidth < maxHeight) maxWidth else maxHeight
                if (bitmap != null && app != null) {
                    Image(
                        bitmap = bitmap,
                        contentDescription = app.name,
                        modifier = Modifier
                            .size(side)
                            .clip(RoundedCornerShape(radius)),
                        contentScale = ContentScale.Crop,
                    )
                } else if (app != null) {
                    Text(
                        text = app.name.take(1).uppercase(),
                        color = DeckPalette.Text,
                        fontSize = 32.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            if (app != null) {
                Text(
                    text = app.name,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 5.dp, end = 18.dp),
                    color = Color.White,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                )
            }
        }
        if (pressed && !dragging) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.White.copy(alpha = 0.14f)),
            )
        }
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .size(44.dp)
                .clickable(
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                    indication = ripple(bounded = false, radius = 18.dp, color = Color.White),
                    onClick = { onLink(index) },
                ),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(26.dp)
                    .clip(CircleShape)
                    .background(Color(0xE61A1A1C))
                    .border(1.dp, Color.White.copy(alpha = 0.22f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Add,
                    contentDescription = addDescription,
                    tint = Color.White,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

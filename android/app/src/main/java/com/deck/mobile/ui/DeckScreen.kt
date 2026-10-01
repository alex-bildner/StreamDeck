package com.deck.mobile.ui

import android.app.Activity
import android.view.HapticFeedbackConstants
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemGestures
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.deck.mobile.data.DiscoveredMac
import com.deck.mobile.data.MacDiscovery
import com.deck.mobile.model.Connection
import com.deck.mobile.model.DeckApp
import com.deck.mobile.model.DeckSlot
import kotlin.math.abs
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private const val PAGE_COUNT = 3
private const val CLOCK_PAGE = 2

@Composable
fun DeckScreen(viewModel: DeckViewModel) {
    val slots by viewModel.slots.collectAsStateWithLifecycle()
    val links by viewModel.links.collectAsStateWithLifecycle()
    val connection by viewModel.connection.collectAsStateWithLifecycle()
    val apps by viewModel.apps.collectAsStateWithLifecycle()
    val appsLoading by viewModel.appsLoading.collectAsStateWithLifecycle()
    val appsError by viewModel.appsError.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var showConnect by rememberSaveable { mutableStateOf(false) }
    var askedConnect by rememberSaveable { mutableStateOf(false) }
    var linkIndex by rememberSaveable { mutableStateOf<Int?>(null) }
    var browserIndex by rememberSaveable { mutableStateOf<Int?>(null) }
    var savingId by remember { mutableStateOf<String?>(null) }
    var editingIcons by rememberSaveable { mutableStateOf(false) }
    var iconEdit by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    var pendingIcon by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    val pageSwipe = remember { PageSwipeGate() }
    val pagerState = rememberPagerState(pageCount = { PAGE_COUNT })
    val discovered = remember { mutableStateListOf<DiscoveredMac>() }
    val context = LocalContext.current
    val view = LocalView.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val pageSpring = spring<Float>(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow)
    var settleJob by remember { mutableStateOf<Job?>(null) }
    val pickIcon = rememberLauncherForActivityResult(PickVisualMedia()) { uri ->
        val target = pendingIcon
        if (uri != null && target != null) viewModel.setSlotIcon(target.first, target.second, uri)
        pendingIcon = null
    }

    LaunchedEffect(Unit) {
        viewModel.messages.collect { snackbar.showSnackbar(it) }
    }
    LaunchedEffect(connection) {
        if (connection is Connection.NoHost && !askedConnect) {
            askedConnect = true
            showConnect = true
        }
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) viewModel.refreshConnection()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        if (lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            viewModel.refreshConnection()
        }
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(linkIndex) {
        if (linkIndex != null) viewModel.loadApps()
    }
    DisposableEffect(view) {
        val window = (view.context as? Activity)?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, view) }
        controller?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller?.hide(WindowInsetsCompat.Type.systemBars())
        onDispose { controller?.show(WindowInsetsCompat.Type.systemBars()) }
    }
    DisposableEffect(context) {
        val discovery = MacDiscovery(context)
        discovery.start(
            onFound = { mac ->
                val index = discovered.indexOfFirst { it.name == mac.name }
                if (index >= 0) discovered[index] = mac else discovered.add(mac)
            },
            onLost = { name -> discovered.removeAll { it.name == name } },
        )
        onDispose { discovery.stop() }
    }
    SideEffect {
        pageSwipe.page = pagerState.currentPage
        pageSwipe.pageCount = PAGE_COUNT
        pageSwipe.onClaim = { viewModel.cancelReorder() }
        pageSwipe.onDrag = { dx ->
            settleJob?.cancel()
            pageSwipe.committed = false
            pagerState.dispatchRawDelta(-dx)
        }
        pageSwipe.onRelease = {
            val origin = pageSwipe.originPage.coerceIn(0, PAGE_COUNT - 1)
            val position = pagerState.currentPage + pagerState.currentPageOffsetFraction
            val projected = position - pageSwipe.velocityX / pageSwipe.pageWidth * 0.28f
            val nearest = kotlin.math.round(position).toInt().coerceIn(0, PAGE_COUNT - 1)
            val target = when {
                projected >= origin + 0.5f -> maxOf(nearest, origin + 1).coerceAtMost(PAGE_COUNT - 1)
                projected <= origin - 0.5f -> minOf(nearest, origin - 1).coerceAtLeast(0)
                else -> origin
            }
            settleJob = scope.launch {
                pagerState.animateScrollToPage(target, animationSpec = pageSpring)
                if (target != origin) view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(
                if (pagerState.currentPage == CLOCK_PAGE) {
                    Brush.verticalGradient(listOf(Color.Black, Color.Black))
                } else {
                    Brush.verticalGradient(
                        0f to Color(0xFF121214),
                        0.42f to Color(0xFF050506),
                        1f to Color(0xFF000000),
                    )
                },
            )
            .pageSwipe(pageSwipe)
            .windowInsetsPadding(
                WindowInsets.displayCutout.union(
                    WindowInsets.systemGestures.only(WindowInsetsSides.Bottom),
                ),
            ),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 12.dp, vertical = 8.dp),
        ) {
            HorizontalPager(
                state = pagerState,
                userScrollEnabled = false,
                beyondViewportPageCount = 1,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) { target ->
                if (target == 0) {
                    DeckGrid(
                        slots = slots,
                        iconFor = { id -> viewModel.icons[id] },
                        customIcon = { key -> viewModel.customIcons[key] },
                        editingIcons = editingIcons,
                        onEditIcon = { index -> iconEdit = 0 to index },
                        onMove = viewModel::move,
                        onLaunch = viewModel::launch,
                        onLink = { index -> linkIndex = index },
                        onDragFinished = viewModel::commitReorder,
                        pageSwipe = pageSwipe,
                    )
                } else if (target == 1) {
                    DeckGrid(
                        slots = links.map { slot ->
                            DeckSlot(
                                key = slot.key,
                                app = slot.link?.let { DeckApp(it.url, it.title) },
                            )
                        },
                        iconFor = { _ -> null },
                        customIcon = { key -> viewModel.customIcons[key] },
                        editingIcons = editingIcons,
                        onEditIcon = { index -> iconEdit = 1 to index },
                        onMove = viewModel::moveLink,
                        onLaunch = viewModel::openLink,
                        onLink = { index -> browserIndex = index },
                        onDragFinished = viewModel::commitReorder,
                        pageSwipe = pageSwipe,
                        addDescription = "Adicionar link",
                    )
                } else {
                    ClockScreen(
                        pageSwipe = pageSwipe,
                        active = pagerState.currentPage == CLOCK_PAGE,
                    )
                }
            }
            if (pagerState.currentPage != CLOCK_PAGE) PageMenu(
                page = pagerState.currentPage,
                editingIcons = editingIcons,
                connection = connection,
                onSelect = { index ->
                    viewModel.cancelReorder()
                    scope.launch { pagerState.animateScrollToPage(index, animationSpec = pageSpring) }
                },
                onEditIcons = { editingIcons = !editingIcons },
                onConnect = { showConnect = true },
            )
        }
        SnackbarHost(
            hostState = snackbar,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 76.dp),
        ) { data ->
            Snackbar(
                snackbarData = data,
                containerColor = Color(0xFF2A2A2E),
                contentColor = Color.White,
                shape = RoundedCornerShape(16.dp),
            )
        }
    }

    if (showConnect) {
        val endpoint = viewModel.endpoint
        val address = when {
            endpoint == null -> ""
            endpoint.port == 8765 -> endpoint.host
            else -> "${endpoint.host}:${endpoint.port}"
        }
        ConnectDialog(
            initialAddress = address,
            initialToken = endpoint?.token.orEmpty(),
            discovered = discovered,
            onDismiss = { showConnect = false },
            onConnect = viewModel::connect,
        )
    }

    val editing = linkIndex
    if (editing != null) {
        AppPickerSheet(
            apps = apps,
            loading = appsLoading,
            error = appsError,
            current = slots.getOrNull(editing)?.app,
            savingId = savingId,
            iconFor = { id -> viewModel.icons[id] },
            onRequestIcon = viewModel::requestIcon,
            onPick = { app ->
                scope.launch {
                    savingId = app.id
                    val message = viewModel.assign(editing, app)
                    savingId = null
                    if (message == null) {
                        linkIndex = null
                    } else {
                        snackbar.showSnackbar(message)
                    }
                }
            },
            onClear = {
                viewModel.clear(editing)
                linkIndex = null
            },
            onRetry = viewModel::loadApps,
            onDismiss = { if (savingId == null) linkIndex = null },
        )
    }

    val editingLink = browserIndex
    if (editingLink != null) {
        val current = links.getOrNull(editingLink)?.link
        LinkEditorDialog(
            initialTitle = current?.title.orEmpty(),
            initialUrl = current?.url.orEmpty(),
            onDismiss = { browserIndex = null },
            onSave = { title, url -> viewModel.setLink(editingLink, title, url) },
            onRemove = if (current == null) {
                null
            } else {
                { viewModel.clearLink(editingLink) }
            },
        )
    }

    val editingIcon = iconEdit
    if (editingIcon != null) {
        IconEditDialog(
            hasCustom = viewModel.hasSlotIcon(editingIcon.first, editingIcon.second),
            onPick = {
                pendingIcon = editingIcon
                iconEdit = null
                pickIcon.launch(PickVisualMediaRequest(PickVisualMedia.ImageOnly))
            },
            onClear = {
                viewModel.clearSlotIcon(editingIcon.first, editingIcon.second)
                iconEdit = null
            },
            onDismiss = { iconEdit = null },
        )
    }
}

@Composable
private fun PageMenu(
    page: Int,
    editingIcons: Boolean,
    connection: Connection,
    onSelect: (Int) -> Unit,
    onEditIcons: () -> Unit,
    onConnect: () -> Unit,
) {
    val dot = when (connection) {
        is Connection.Online -> DeckPalette.Online
        is Connection.Checking -> Color(0xFFFFC857)
        else -> DeckPalette.Offline
    }
    Box(
        Modifier
            .fillMaxWidth()
            .padding(top = 4.dp)
            .height(40.dp),
    ) {
        Row(
            Modifier.align(Alignment.Center),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            repeat(PAGE_COUNT) { index ->
                PageDot(selected = page == index) { onSelect(index) }
            }
        }
        Row(
            Modifier.align(Alignment.CenterEnd),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onConnect),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier
                        .size(5.dp)
                        .background(dot, CircleShape),
                )
            }
            Box(
                Modifier
                    .padding(end = 2.dp)
                    .size(36.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onEditIcons),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Edit,
                    contentDescription = if (editingIcons) "Concluir edição de ícones" else "Editar ícones",
                    tint = Color.White.copy(alpha = if (editingIcons) 1f else 0.55f),
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun PageDot(selected: Boolean, onClick: () -> Unit) {
    val size by animateDpAsState(
        targetValue = if (selected) 8.dp else 5.dp,
        animationSpec = spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessMediumLow),
        label = "pageDot",
    )
    Box(
        Modifier
            .size(28.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(size)
                .background(
                    Color.White.copy(alpha = if (selected) 0.95f else 0.32f),
                    CircleShape,
                ),
        )
    }
}

@Composable
private fun IconEditDialog(
    hasCustom: Boolean,
    onPick: () -> Unit,
    onClear: () -> Unit,
    onDismiss: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(28.dp),
            color = Color(0xFF1A1A1C),
        ) {
            Column(Modifier.padding(22.dp)) {
                Text(
                    text = "Editar ícone",
                    color = DeckPalette.Text,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = "A imagem fica neste atalho. O app ou o link continuam os mesmos.",
                    color = DeckPalette.Muted,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(top = 8.dp, bottom = 18.dp),
                )
                Button(
                    onClick = onPick,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    shape = RoundedCornerShape(16.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color.White,
                        contentColor = Color.Black,
                    ),
                ) {
                    Text("Escolher imagem", fontWeight = FontWeight.SemiBold)
                }
                if (hasCustom) {
                    TextButton(onClick = onClear, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                        Text("Usar o ícone original", color = DeckPalette.Offline)
                    }
                }
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                    Text("Agora não", color = DeckPalette.Muted)
                }
            }
        }
    }
}

private fun Modifier.pageSwipe(gate: PageSwipeGate): Modifier =
    onGloballyPositioned { gate.pagerCoordinates = it }
        .pointerInput(gate) {
            val threshold = 12.dp.toPx()
            gate.pageWidth = size.width.toFloat().coerceAtLeast(1f)
            awaitEachGesture {
                gate.claimPage = false
                val startPage = gate.page
                val down = awaitFirstDown(pass = PointerEventPass.Initial, requireUnconsumed = false)
                if (gate.coversCalendar(down.position)) {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                    }
                    return@awaitEachGesture
                }
                val tracker = VelocityTracker()
                var total = Offset.Zero
                var claimed = false
                var sent = 0f
                while (true) {
                    val event = awaitPointerEvent(PointerEventPass.Initial)
                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) {
                        if (claimed) {
                            gate.velocityX = tracker.calculateVelocity().x
                            gate.onRelease()
                        }
                        gate.claimPage = false
                        break
                    }
                    tracker.addPointerInputChange(change)
                    total += change.position - change.previousPosition
                    val horizontal = abs(total.x) > threshold && abs(total.x) > abs(total.y)
                    val forward = horizontal && total.x < 0 && startPage < gate.pageCount - 1
                    val back = horizontal && total.x > 0 && startPage > 0
                    if (!claimed && (forward || back)) {
                        claimed = true
                        gate.claimPage = true
                        gate.originPage = startPage
                        gate.committed = false
                        gate.onClaim()
                    }
                    if (claimed) {
                        val delta = total.x - sent
                        sent = total.x
                        if (delta != 0f) gate.onDrag(delta)
                    }
                }
            }
        }


package com.deck.mobile.ui

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color as AndroidColor
import android.graphics.Typeface
import android.os.Build
import android.text.format.DateFormat
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.LocalDate
import java.time.LocalTime
import java.time.YearMonth
import java.time.format.TextStyle as JavaTextStyle
import java.time.temporal.WeekFields
import java.util.Locale

private val SolarFont = FontFamily(Typeface.create("sans-serif-rounded", Typeface.BOLD))

private val ClockColors = listOf(
    Color(0xFFFF453A),
    Color(0xFFFF6A00),
    Color(0xFFFF9F0A),
    Color(0xFFFFD60A),
    Color(0xFFC5F467),
    Color(0xFF34C759),
    Color(0xFF63E6BE),
    Color(0xFF5AC8F5),
    Color(0xFF0A84FF),
    Color(0xFF5E5CE6),
    Color(0xFFBF5AF2),
    Color(0xFFFF375F),
    Color(0xFFFF8AD8),
    Color(0xFFFFFFFF),
)

private data class ClockMoment(val time: LocalTime, val date: LocalDate)

@Composable
fun ClockScreen(pageSwipe: PageSwipeGate, active: Boolean) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("deck-clock", Context.MODE_PRIVATE) }
    var colorIndex by remember {
        mutableIntStateOf(prefs.getInt("color", 2).coerceIn(0, ClockColors.lastIndex))
    }
    var picking by remember { mutableStateOf(false) }
    val moment = rememberMoment()
    val hour24 = DateFormat.is24HourFormat(context)
    val accent = ClockColors[colorIndex]
    val digits = remember(accent) { solarDigits(accent) }
    val open = remember { MutableInteractionSource() }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 8.dp)) {
            if (maxWidth > maxHeight) {
                Row(
                    Modifier.fillMaxSize(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SolarClock(
                        moment.time,
                        hour24,
                        digits,
                        Modifier
                            .weight(1.05f)
                            .fillMaxSize()
                            .clickable(interactionSource = open, indication = null) { picking = true },
                    )
                    MonthCalendar(moment.date, accent, active, pageSwipe, Modifier.weight(0.95f).fillMaxSize())
                }
            } else {
                Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                    SolarClock(
                        moment.time,
                        hour24,
                        digits,
                        Modifier
                            .weight(1.05f)
                            .fillMaxWidth()
                            .clickable(interactionSource = open, indication = null) { picking = true },
                    )
                    MonthCalendar(moment.date, accent, active, pageSwipe, Modifier.weight(0.95f).fillMaxWidth())
                }
            }
        }
        if (picking) {
            val scrim = remember { MutableInteractionSource() }
            Box(
                Modifier
                    .fillMaxSize()
                    .clickable(interactionSource = scrim, indication = null) { picking = false },
            )
            ColorSheet(
                selected = colorIndex,
                onSelect = { index ->
                    colorIndex = index
                    prefs.edit().putInt("color", index).apply()
                },
                onClose = { picking = false },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

@Composable
private fun SolarClock(
    time: LocalTime,
    hour24: Boolean,
    colors: List<Color>,
    modifier: Modifier = Modifier,
) {
    val stamp = "%02d%02d".format(displayedHour(time.hour, hour24), time.minute)
    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val digit = minOf(maxHeight * 0.72f, maxWidth / 4.15f)
        val fontSize = with(LocalDensity.current) { digit.toSp() }
        val style = TextStyle(
            fontFamily = SolarFont,
            fontWeight = FontWeight.Black,
            fontSize = fontSize,
            textAlign = TextAlign.Center,
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy((-digit * 0.04f)),
        ) {
            RollingDigit(stamp[0], colors[0], style)
            RollingDigit(stamp[1], colors[1], style)
            Colon(digit * 0.11f, Color.White.copy(alpha = 0.86f))
            RollingDigit(stamp[2], colors[2], style)
            RollingDigit(stamp[3], colors[3], style)
        }
    }
}

@Composable
private fun Colon(dot: Dp, color: Color) {
    Column(
        Modifier.padding(horizontal = dot * 0.7f),
        verticalArrangement = Arrangement.spacedBy(dot * 0.85f),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        repeat(2) {
            Box(
                Modifier
                    .size(dot)
                    .clip(CircleShape)
                    .background(color),
            )
        }
    }
}

@Composable
private fun RollingDigit(char: Char, color: Color, style: TextStyle) {
    Box(Modifier.clipToBounds()) {
        AnimatedContent(
            targetState = char,
            transitionSpec = {
                (slideInVertically { height -> height } + fadeIn(tween(260)))
                    .togetherWith(slideOutVertically { height -> -height } + fadeOut(tween(180)))
            },
            label = "solar-digit",
        ) { value ->
            Text(text = value.toString(), style = style, color = color)
        }
    }
}

private const val MONTH_COUNT = 2500 * 12

private fun monthIndex(month: YearMonth): Int {
    return ((month.year - 1) * 12 + month.monthValue - 1).coerceIn(0, MONTH_COUNT - 1)
}

private fun monthAt(index: Int): YearMonth {
    val safe = index.coerceIn(0, MONTH_COUNT - 1)
    return YearMonth.of(safe / 12 + 1, safe % 12 + 1)
}

@Composable
private fun MonthCalendar(
    today: LocalDate,
    accent: Color,
    active: Boolean,
    pageSwipe: PageSwipeGate,
    modifier: Modifier = Modifier,
) {
    val todayIndex = monthIndex(YearMonth.from(today))
    val pagerState = androidx.compose.foundation.pager.rememberPagerState(initialPage = todayIndex) { MONTH_COUNT }
    LaunchedEffect(active) {
        if (!active) pagerState.scrollToPage(monthIndex(YearMonth.now()))
    }
    DisposableEffect(pageSwipe) {
        onDispose { pageSwipe.calendarCoordinates = null }
    }
    val shape = RoundedCornerShape(24.dp)
    Box(
        modifier
            .clip(shape)
            .border(1.dp, Color.White.copy(alpha = 0.16f), shape)
            .onGloballyPositioned { pageSwipe.calendarCoordinates = it },
    ) {
        androidx.compose.foundation.pager.HorizontalPager(
            state = pagerState,
            beyondViewportPageCount = 1,
            modifier = Modifier.fillMaxSize(),
        ) { page ->
            MonthFace(
                month = monthAt(page),
                today = today,
                accent = accent,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
private fun MonthFace(
    month: YearMonth,
    today: LocalDate,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    val locale = remember { Locale.getDefault() }
    val weekFields = remember(locale) { WeekFields.of(locale) }
    val first = remember(month) { month.atDay(1) }
    val title = remember(month, locale) {
        first.month.getDisplayName(JavaTextStyle.FULL, locale).uppercase(locale)
    }
    val headers = remember(locale, weekFields) {
        val start = weekFields.firstDayOfWeek
        List(7) { index ->
            val day = start.plus(index.toLong())
            day.getDisplayName(JavaTextStyle.NARROW, locale).take(1).uppercase(locale)
        }
    }
    val weeks = remember(month, weekFields) { monthWeeks(first, weekFields) }
    val ink = if (isLight(accent)) Color.Black else Color.White
    val sameMonth = month.year == today.year && month.monthValue == today.monthValue

    BoxWithConstraints(modifier, contentAlignment = Alignment.Center) {
        val cell = minOf(maxWidth / 7.4f, maxHeight / 8.6f)
        val daySize = with(LocalDensity.current) { (cell * 0.42f).toSp() }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = title,
                color = accent,
                fontSize = with(LocalDensity.current) { (cell * 0.38f).toSp() },
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.6.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(bottom = cell * 0.28f),
            )
            Row(horizontalArrangement = Arrangement.SpaceEvenly) {
                headers.forEach { label ->
                    Box(Modifier.size(cell), contentAlignment = Alignment.Center) {
                        Text(
                            text = label,
                            color = Color.White.copy(alpha = 0.42f),
                            fontSize = daySize * 0.72f,
                            fontWeight = FontWeight.Medium,
                        )
                    }
                }
            }
            weeks.forEach { week ->
                Row(horizontalArrangement = Arrangement.SpaceEvenly) {
                    week.forEach { day ->
                        val marked = sameMonth && day == today.dayOfMonth
                        Box(Modifier.size(cell), contentAlignment = Alignment.Center) {
                            if (day != null) {
                                Box(
                                    Modifier
                                        .size(cell * 0.78f)
                                        .clip(CircleShape)
                                        .background(if (marked) accent else Color.Transparent),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = day.toString(),
                                        color = if (marked) ink else Color.White.copy(alpha = 0.92f),
                                        fontSize = daySize,
                                        fontWeight = if (marked) FontWeight.SemiBold else FontWeight.Normal,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ColorSheet(
    selected: Int,
    onSelect: (Int) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val panel = remember { MutableInteractionSource() }
    Column(
        modifier
            .padding(horizontal = 16.dp, vertical = 14.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(26.dp))
            .background(Color(0xFF1C1C1E))
            .clickable(interactionSource = panel, indication = null) {}
            .padding(start = 18.dp, end = 12.dp, top = 12.dp, bottom = 18.dp),
    ) {
        Box(Modifier.fillMaxWidth().padding(bottom = 14.dp)) {
            Text(
                text = "Cor",
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.Center),
            )
            val close = remember { MutableInteractionSource() }
            Box(
                Modifier
                    .align(Alignment.CenterEnd)
                    .size(30.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.14f))
                    .clickable(interactionSource = close, indication = null, onClick = onClose),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = "Fechar",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            itemsIndexed(ClockColors) { index, color ->
                val chosen = index == selected
                val dot = remember(index) { MutableInteractionSource() }
                Box(
                    Modifier
                        .size(if (chosen) 34.dp else 28.dp)
                        .clip(CircleShape)
                        .border(
                            width = if (chosen) 2.dp else 0.dp,
                            color = Color.White,
                            shape = CircleShape,
                        )
                        .padding(if (chosen) 4.dp else 0.dp)
                        .clip(CircleShape)
                        .background(color)
                        .clickable(interactionSource = dot, indication = null) { onSelect(index) },
                )
            }
        }
    }
}

@Composable
private fun rememberMoment(): ClockMoment {
    val context = LocalContext.current
    var moment by remember { mutableStateOf(currentMoment()) }
    DisposableEffect(context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                moment = currentMoment()
            }
        }
        val filter = IntentFilter(Intent.ACTION_TIME_TICK).apply {
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
            addAction(Intent.ACTION_DATE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        onDispose { context.unregisterReceiver(receiver) }
    }
    return moment
}

private fun currentMoment(): ClockMoment {
    return ClockMoment(LocalTime.now().withSecond(0).withNano(0), LocalDate.now())
}

private fun monthWeeks(date: LocalDate, weekFields: WeekFields): List<List<Int?>> {
    val first = date.withDayOfMonth(1)
    val lead = first.get(weekFields.dayOfWeek()) - 1
    val days = date.lengthOfMonth()
    val cells = MutableList<Int?>(lead) { null }
    for (day in 1..days) cells += day
    while (cells.size % 7 != 0) cells += null
    return cells.chunked(7)
}

private fun displayedHour(hour: Int, hour24: Boolean): Int {
    if (hour24) return hour
    val wrapped = hour % 12
    return if (wrapped == 0) 12 else wrapped
}

private fun solarDigits(base: Color): List<Color> {
    val hsv = FloatArray(3)
    AndroidColor.colorToHSV(base.toArgb(), hsv)
    if (hsv[1] < 0.08f) {
        return listOf(
            Color(0xFFFF8A3D),
            Color(0xFF8FD3FF),
            Color(0xFF3D7DFF),
            Color(0xFFFF7A2F),
        )
    }
    return listOf(
        tint(base, 0f, hsv[1].coerceIn(0.55f, 0.9f), 1f),
        tint(base, 168f, 0.38f, 1f),
        tint(base, 205f, 0.62f, 1f),
        tint(base, 22f, hsv[1].coerceIn(0.5f, 0.85f), 1f),
    )
}

private fun tint(base: Color, hueDelta: Float, saturation: Float, value: Float): Color {
    val hsv = FloatArray(3)
    AndroidColor.colorToHSV(base.toArgb(), hsv)
    hsv[0] = (hsv[0] + hueDelta + 360f) % 360f
    hsv[1] = saturation.coerceIn(0f, 1f)
    hsv[2] = value.coerceIn(0f, 1f)
    return Color(AndroidColor.HSVToColor(hsv))
}

private fun isLight(color: Color): Boolean {
    val argb = color.toArgb()
    val red = AndroidColor.red(argb) / 255f
    val green = AndroidColor.green(argb) / 255f
    val blue = AndroidColor.blue(argb) / 255f
    return red * 0.299f + green * 0.587f + blue * 0.114f > 0.72f
}

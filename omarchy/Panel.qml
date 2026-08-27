pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Claude usage panel. Owns the claudebar --json data (polled through a
// Process + Timer) and renders one section per usage window: name, animated
// progress meter with an elapsed-time marker at the pace point, percent,
// reset countdown, and pacing indicator. Severity thresholds come from the
// CLI ("state" fields); only the colors are decided here, interpolated
// between theme tokens so every Omarchy theme works.
Panel {
  id: root
  moduleName: "mryll.claudebar"
  ipcTarget: "mryll.claudebar"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget (popout coordinator, switchPanelFrom).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The panel draws on the POPUP CARD, so it takes the popup surface's text
  // token — not the bar's. bar.foreground is chosen against the bar, which on a
  // transparent bar means "against the wallpaper"; that is the wrong contrast
  // reference for a card, and a theme that defines popups.text separately would
  // be ignored outright. (printbar already did this; the rest of the family now
  // agrees.)
  readonly property color foreground: Color.popups.text
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)

  // ---- Freshness suffix tint, shared by the whole family.
  //
  // The timestamp is ALWAYS dim: "when is this from" is information, not a
  // warning. Only the "· stale (…)" suffix carries color, and only a muted
  // warning tone — never full urgent, which is reserved for something the user
  // must act on. Text stays the primary carrier; the tint only reinforces it,
  // so a monochrome panel loses nothing.
  readonly property color freshnessWarn: panelColored ? mix(dim, urgent, 0.4) : dim
  readonly property color track: Style.selectedFillFor(foreground, Color.accent, urgent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // ---------------------------------------------------------------- data
  //
  // Last good claudebar --json parse. Kept on any failure so the bar never
  // flashes empty: a transient error only dims the icon and surfaces the
  // message in the panel footer.
  property var usage: null
  readonly property bool hasData: usage !== null
  property string loadError: ""
  property bool loading: false

  // Countdowns and "updated" read this instead of Date.now() so an open
  // panel keeps telling the truth.
  property double nowMs: Date.now()

  // Monochrome modes, mirroring the CLI's --no-color states: "full" (default),
  // "none", "bar-only" (colored bar, plain panel) and "panel-only". Monochrome
  // means foreground tones only — no ramp, no accent, no urgent — and severity
  // keeps reading through the numbers and glyphs, which is what a user asking
  // for no colors is choosing. The CLI is never asked for --no-color: the
  // structured JSON is colorless data, and this widget decides its own look.
  // An unrecognized value normalizes to "full": a hand-edited shell.json must
  // not be able to silently take the color off both surfaces.
  readonly property string colorMode: {
    var v = String(setting("colorMode", "full"))
    return ["full", "none", "bar-only", "panel-only"].indexOf(v) >= 0 ? v : "full"
  }
  readonly property bool barColored:   colorMode === "full" || colorMode === "bar-only"
  readonly property bool panelColored: colorMode === "full" || colorMode === "panel-only"

  readonly property int refreshSec: Math.max(60, parseInt(setting("refreshIntervalSec", 300), 10) || 300)
  readonly property bool showLabel: setting("showLabel", true) === true
  readonly property string barWindowSetting: String(setting("barWindow", "Session"))

  readonly property string binName: "claudebar"

  // One constant, two users: the error message shows it and the copy
  // button copies it.
  readonly property string installCmd: "yay -S claudebar"

  // Process run state machine: the collector and the exit signal race, so a
  // run only finalizes once both have reported (with a timer fallback for
  // failed starts where the collector never fires). A refresh requested while
  // a run is in flight is queued — last command wins — instead of dropped.
  property bool collectorDone: true
  property bool processDone: true

  // A fetch is in flight. BOTH halves matter: the exit code and the collected
  // stdout arrive in either order, which is exactly why maybeFinalize() waits
  // for the pair. The refresh button gates on this, not on collectorDone alone
  // — otherwise it re-enables in the gap between the two signals and a click
  // there queues a second run through pendingCmd, which is the one thing its
  // disabled state promises cannot happen.
  readonly property bool fetchBusy: !collectorDone || !processDone
  property string capturedText: ""
  property int exitCode: 0
  property var pendingCmd: null

  // True when this run's collector refused oversize output. Its message
  // must survive finalizeRun; a stale error from a previous run must not.
  property bool tripwireFired: false

  // True when onExited fired for the current run. A missing command emits
  // no exited. This separates "could not start" from "ran, no output".
  // Probed live: exited always arrives before running drops.
  property bool sawExit: false

  // The command that runs. PATH first, always: the AUR release must win
  // when it exists. Changes to bundledCmd only after a failed START, and
  // keeps that value until the shell restarts.
  property string resolvedBin: binName

  // Set by BarWidget.qml: path of the script inside the plugin clone.
  // Empty = no fallback.
  property string bundledCmd: ""

  // Args of the current run, for the fallback retry.
  property var lastArgs: []

  // True only when PATH and bundle both failed to START. Gates the copy
  // button. Operational errors never set it.
  property bool notInstalled: false

  function buildCmd(force) {
    return force ? ["--json", "--refresh"] : ["--json"]
  }

  function refresh(force) {
    startRun(buildCmd(force === true))
  }

  function startRun(args) {
    if (statusProc.running) { pendingCmd = args; return }
    collectorDone = false
    processDone = false
    capturedText = ""
    sawExit = false
    tripwireFired = false
    exitCode = 0
    lastArgs = args
    statusProc.command = [resolvedBin].concat(args)
    statusProc.running = true
  }

  function maybeFinalize() {
    if (!collectorDone || !processDone) return
    exitFallback.stop()
    finalizeRun()
  }

  function setError(message) {
    loadError = String(message)
    loading = false
    // The last good payload stays on screen — that is deliberate — but it must
    // stop claiming to be current. Without this the footer keeps printing a
    // plain "Updated HH:MM" for data the CLI can no longer refresh (binary
    // gone, malformed output, hard error), which is precisely the promise the
    // freshness line is supposed to keep.
    pluginStale = true
  }

  // Set when the plugin's own run fails, cleared by the next good parse. ORed
  // into `stale` so a failure here is reported the same way the CLI's own
  // cache staleness is.
  property bool pluginStale: false

  function finalizeRun() {
    notInstalled = false
    var text = capturedText.trim()
    if (text === "") {
      // Empty output has three causes. (1) The tripwire already set an
      // error: keep it. (2) No exited = failed start: try the bundled
      // copy once, or report not-installed. (3) The process ran and
      // printed nothing: an operational error, never "not installed".
      if (tripwireFired) {
        // Already explained by this run's tripwire. Nothing to add.
      } else if (!sawExit) {
        if (resolvedBin === binName && bundledCmd !== "") {
          // Switch to the clone's copy and re-run this request. The early
          // return leaves pendingCmd for the retry's finalize.
          resolvedBin = bundledCmd
          var args = lastArgs
          Qt.callLater(function() { startRun(args) })
          return
        }
        notInstalled = true
        setError(binName + " could not start — not installed or not on PATH?\n\n"
                 + "Install it with:  " + installCmd + "\n"
                 + (resolvedBin !== binName
                    ? "(the bundled copy at " + resolvedBin + " also failed to start)\n"
                    : "")
                 + "Then open this panel again.")
      } else {
        setError(binName + " produced no output (exit " + exitCode + ")")
      }
    } else {
      handle(text)
    }
    if (pendingCmd) {
      var c = pendingCmd
      pendingCmd = null
      Qt.callLater(function() { startRun(c) })
    }
  }

  // Keeps last-known-good usage on ANY failure, but always surfaces an
  // explicit error on nonempty-but-malformed output — never a silent swallow.
  // A valid structured error document wins over a generic exit-code message.
  function handle(out) {
    nowMs = Date.now()
    var d = null
    try { d = JSON.parse(out) } catch (e) { d = null }
    if (d === null || typeof d !== "object") {
      setError(exitCode !== 0
        ? binName + " failed (exit " + exitCode + ")"
        : binName + " returned malformed output")
      return
    }
    // The script stamps every --json document with schema_version 2. This
    // catches an old AUR CLI under a newer panel. A schema bump must change
    // script, panel and tests in one commit.
    if (Number(d.schema_version) !== 2) {
      setError(binName + " returned an unexpected document (not schema_version 2) — mismatched CLI version?")
      return
    }
    if (d.loading === true) {
      // Understood transient state (network settling, no cached data yet).
      loading = true
      loadError = ""
      return
    }
    if (d.error && !(Array.isArray(d.windows) && d.windows.length > 0)) {
      // Hard failure (no credentials, missing dependency, …): no usable
      // windows in this payload, keep the last good data on screen.
      setError(String(d.error.message || "claudebar failed"))
      return
    }
    usage = d
    loading = false
    loadError = ""
    pluginStale = false
  }

  // ---------------------------------------------------------------- model

  // Every usage window the payload carries, in tooltip order: session,
  // weekly, the legacy Sonnet window, then one per model-scoped limit.
  // The CLI publishes the list already ordered and already named; the panel
  // does not rebuild it from named keys any more. Each entry carries `label`
  // (the window inside a meter) and `group` (the meter it belongs to), which
  // is what windowTitle joins.
  readonly property var windows: {
    if (!usage || !Array.isArray(usage.windows)) return []
    var out = []
    for (var i = 0; i < usage.windows.length; i++) {
      var w = usage.windows[i]
      if (!w) continue
      out.push({ title: windowTitle(w), w: w })
    }
    return out
  }

  function windowTitle(w) {
    if (!w) return ""
    var label = String(w.label || "")
    return w.group ? String(w.group) + " · " + label : label
  }

  function windowById(id) {
    if (!usage || !Array.isArray(usage.windows)) return null
    for (var i = 0; i < usage.windows.length; i++)
      if (usage.windows[i] && String(usage.windows[i].id) === id) return usage.windows[i]
    return null
  }

  readonly property var extra: usage ? (usage.extra_usage || null) : null
  readonly property string extraSpentSummary: {
    if (!extra) return ""
    var total = extra.balance_known === true ? money(extra.funded_credit_cents) : "—"
    return "Spent: " + money(extra.used_credit_cents) + " / " + total
  }
  readonly property string extraCreditSummary: {
    if (!extra) return ""
    var available = extra.balance_known === true ? money(extra.available_credit_cents) : "—"
    return "Available: " + available + " · Monthly limit: " + money(extra.monthly_limit_cents)
  }
  readonly property bool stale: pluginStale || !!(usage && usage.stale === true)
  // `error` is a hard failure with no document; `last_error` is an API error
  // sitting behind data that is still usable. This panel renders the latter.
  readonly property var apiError: usage ? (usage.last_error || null) : null

  // ---------------------------------------------------------------- bar face

  readonly property var barWindowData: windowById(barWindowSetting === "Weekly" ? "weekly" : "session")

  readonly property string barLabel: {
    if (!showLabel || vertical || !barWindowData) return ""
    return Math.round(Number(barWindowData.used_pct || 0)) + "%"
  }

  // The percentage the bar shows, and the gauge color for exactly that value —
  // the same tone the panel gives the same number. Tinting by the worst window
  // instead would describe a value the label isn't showing. A contrast floor
  // keeps a pale ramp color readable without discarding its hue.
  readonly property real barWindowPct: barWindowData ? Number(barWindowData.used_pct || 0) : 0

  readonly property color barFaceForeground: bar ? bar.barForeground : Color.foreground
  readonly property color barFaceDim: Qt.darker(barFaceForeground, 1.55)

  // The bar face paints the ramp at the value it shows — the SAME tone the panel
  // gives that same number, so the two never disagree about one percentage.
  // Freshness is not a color: a blend toward the muted shade (and, before that,
  // dimming the whole button to 45% opacity) restated staleness in the one
  // channel that already means "how much is used", so 27% read as two different
  // colors depending on whether the last poll happened to fail. Staleness gets
  // its own mark instead — the same ⏸ the CLI appends to the waybar text.
  // Only "no data at all" falls back to the muted shade, because then there is
  // no value to color.
  readonly property color barColor: {
    if (!hasData) return barFaceDim
    return barColored
      ? contrastFloor(usageColor(barWindowPct), barBackdrop, barFaceForeground, 4.5)
      : barFaceForeground
  }

  // Serving cached data. Drawn on the bar as ⏸, matching the CLI's bar text.
  readonly property bool barStale: hasData && stale

  // The peripheral "something else is maxed out" signal the worst-window tint
  // used to carry, kept as a separate mark so it never recolors the number:
  // the windows OTHER than the one on the bar that are at critical level,
  // named and quantified so the mark can explain itself on hover.
  readonly property var criticalOthers: {
    if (!usage) return []
    var shown = barWindowData
    var out = []
    for (var i = 0; i < windows.length; i++) {
      var entry = windows[i]
      if (!entry.w || entry.w === shown) continue
      if (String(entry.w.state || "") !== "critical") continue
      out.push(entry)
    }
    return out
  }

  readonly property bool hasCriticalOther: criticalOthers.length > 0

  // Names the offender so the dot explains itself instead of being a mystery
  // mark: "Weekly: 100%", one line each when several are spent.
  readonly property string criticalOthersText: {
    var lines = []
    for (var i = 0; i < criticalOthers.length; i++) {
      var entry = criticalOthers[i]
      lines.push(entry.title + ": " + Math.round(Number(entry.w.used_pct || 0)) + "%")
    }
    return lines.join("\n")
  }

  // The shell's shared tooltip renders this, outside the plugin's control, so
  // the API-supplied window names are escaped and then wrapped: the <span>
  // forces AutoText into rich-text mode, which is what makes the escaped
  // entities decode instead of showing up as &amp;.
  function safeTooltip(s) {
    return "<span>" + String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/\n/g, "<br/>") + "</span>"
  }

  // Empty when there is no mark — Bar.showTooltip short-circuits on empty text,
  // so the bar face stays tooltip-free in the normal case and the panel remains
  // the detail view.
  readonly property string barTooltip: {
    var parts = []
    if (hasCriticalOther) parts.push(criticalOthersText)
    if (barStale) parts.push(" Stale — showing the last data from " + (updatedText() || "earlier"))
    return parts.length > 0 ? safeTooltip(parts.join("\n")) : ""
  }

  // The dot is a warning, so it takes the gauge's critical anchor (under the
  // same contrast floor as the label); monochrome keeps the mark but drops the
  // color, since the tooltip is what carries the meaning.
  readonly property color criticalDotColor: barColored
    ? contrastFloor(gaugeCritical, barBackdrop, barFaceForeground, 4.5)
    : barFaceForeground

  // Dim the icon while there is nothing good to show, or when the CLI is
  // reporting errors behind stale data — the details live in the panel.
  readonly property bool degraded: !hasData || loadError !== "" || apiError !== null

  // Hero brand mark: Claude's own orange, the color Anthropic gives the mark.
  // The glyph is the product's IDENTITY, not a gauge — it never follows the
  // usage ramp (which made the logo change color on every refresh under no
  // rule a reader could name, and restated a value the numbers and meters
  // below already carry) and it never goes urgent either; severity is already
  // said three other ways in this panel.
  //
  // A monochrome panel drops it like every other color. On a light theme the
  // contrast floor blends it toward the panel foreground only as far as it
  // takes to stay legible against the popup surface, so the hue survives
  // wherever it can.
  readonly property color panelBackdrop: Color.popups.background
  readonly property color brandColor: panelColored
    ? contrastFloor(toColor("#D97757"), panelBackdrop, foreground, 3.0)
    : foreground

  // ---------------------------------------------------------------- helpers

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  // ---- gauge palette
  //
  // The meters read as a gauge: green at 0% usage, through amber, to red at
  // the top (inverted against a battery, where empty is the bad end).
  //
  // Why the CLI supplies these at all: the shell's Color singleton exposes
  // foreground, background, accent, urgent and muted — there is no green,
  // amber or orange in it, so a gauge cannot be built from shell tokens alone.
  // The division of labour that follows is deliberate: the CLI owns the RAMP
  // (the value colors and the percentages they turn at), while every color the
  // shell does provide correctly — bar foreground, urgent, the track fill —
  // keeps coming from the shell, because those are transparency-aware and
  // animate with the theme. Do not swap one for a CLI hex; the widget would
  // drift out of step with the rest of the bar.
  //
  // The four anchor colors are resolved by the CLI — Omarchy theme colors, or the user's
  // --color-* overrides — and carried in the JSON's `palette`, so the waybar
  // tooltip and this panel paint from one definition instead of two. An older
  // CLI that omits `palette` falls back to the previous theme foreground →
  // urgent blend, so the panel still renders sanely against cached data.
  readonly property var gaugePalette: usage && usage.palette ? usage.palette : null

  // Fallback for a payload that has not arrived yet (or an older CLI without
  // `palette`): synthesise the anchors from the theme at fixed gauge hues —
  // saturation off urgent, lightness off foreground, both clamped so the ramp
  // stays legible on any theme. The previous fallback blended foreground →
  // urgent, which produced a wash rather than a gauge: green, amber and red
  // are the whole point of the shape and none of them survived it.
  function gaugeColor(hue) {
    var saturation = clamp(urgent.hslSaturation, 0.45, 0.85)
    var lightness = clamp(foreground.hslLightness, 0.32, 0.72)
    return Qt.hsla(hue, saturation, lightness, 1)
  }

  function paletteColor(key, fallback) {
    if (gaugePalette && typeof gaugePalette[key] === "string" && gaugePalette[key].length > 0)
      return gaugePalette[key]
    return fallback
  }

  readonly property color gaugeLow: paletteColor("low", gaugeColor(0.33))
  readonly property color gaugeMid: paletteColor("mid", gaugeColor(0.14))
  readonly property color gaugeHigh: paletteColor("high", gaugeColor(0.07))
  readonly property color gaugeCritical: paletteColor("critical", urgent)

  // Colors arrive from JSON as strings; Qt.darker(c, 1.0) is the identity
  // conversion that turns one into a color object whose channels can be read.
  function toColor(c) { return Qt.darker(c, 1.0) }

  // The ramp exactly as the CLI resolved it: the colors AND the percentages
  // they sit at. Consuming the published stops is what keeps a threshold change
  // in the core from leaving this panel behind, and what carries a --color-*
  // override or a pywal-only machine through to the panel.
  readonly property var gaugeStops: {
    var raw = gaugePalette ? gaugePalette.stops : null
    var out = []
    if (raw && raw.length !== undefined) {
      for (var i = 0; i < raw.length; i++) {
        var entry = raw[i]
        if (!entry) continue
        var pct = Number(entry.pct)
        var col = String(entry.color || "")
        if (!isFinite(pct) || col === "") continue
        out.push({ pct: clamp(pct, 0, 100), color: toColor(col) })
      }
      out.sort(function(a, b) { return a.pct - b.pct })
    }
    if (out.length > 0) return out
    // Nothing published (an older CLI, or no data yet): the theme blend at the
    // thresholds this widget shipped with.
    return [ { pct: 0,  color: gaugeLow },
             { pct: 50, color: gaugeMid },
             { pct: 75, color: gaugeHigh },
             { pct: 90, color: gaugeCritical } ]
  }

  // The gauge as a function of POSITION along the bar: linear between the
  // published anchors, so a percentage is the same color here as in the Waybar
  // tooltip. Used for gradient stops, the percentage figures and the bar face —
  // every surface that stands for a value. Pace arrows are a different
  // dimension and keep their own discrete colors (see paceColor).
  function usageColor(pct) {
    var stops = gaugeStops
    if (stops.length === 0) return foreground
    var p = clamp(Number(pct) || 0, 0, 100)
    if (p <= stops[0].pct) return stops[0].color
    for (var i = stops.length - 1; i >= 0; i--) {
      if (p < stops[i].pct) continue
      if (i === stops.length - 1) return stops[i].color
      var span = stops[i + 1].pct - stops[i].pct
      if (span <= 0) return stops[i].color
      return mix(stops[i].color, stops[i + 1].color, (p - stops[i].pct) / span)
    }
    return stops[0].color
  }


  // The gauge as the PANEL should draw it: plain foreground when the panel is
  // monochrome. Kept separate from usageColor so the bar face can still be
  // colored while the panel is not (and vice versa).
  function panelValueColor(pct) {
    return panelColored ? usageColor(pct) : foreground
  }

  // Pacing severity → color. Only burning fast earns full urgent; slightly
  // ahead gets a nudge; under or on pace stays quiet.
  function paceColor(state) {
    // Monochrome keeps the distinction as lightness rather than hue: burning
    // fast reads at full foreground, everything calmer stays dimmed.
    if (!panelColored) return state === "hot" ? foreground : dim
    if (state === "hot") return urgent
    if (state === "ahead") return mix(dim, urgent, 0.5)
    return dim
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ---- WCAG contrast floor
  //
  // The gauge is chosen for meaning, not for legibility, so a pale ramp color
  // could wash out on the bar. Rather than giving up the ramp there, blend it
  // toward the color the shell already guarantees is readable — only as far as
  // it takes to clear the threshold, so the hue survives wherever it can.
  function relLuminance(c) {
    function chan(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b)
  }

  function contrastRatio(a, b) {
    var la = relLuminance(a), lb = relLuminance(b)
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
  }

  function contrastFloor(c, backdrop, safe, minRatio) {
    if (contrastRatio(c, backdrop) >= minRatio) return c
    for (var t = 1; t <= 10; t++) {
      var blended = mix(c, safe, t / 10)
      if (contrastRatio(blended, backdrop) >= minRatio) return blended
    }
    return safe
  }

  // What the bar label is actually drawn against. An opaque bar paints its own
  // background; a transparent one shows the wallpaper, which we cannot sample —
  // but the shell already did, and picked a light or dark `barForeground`
  // accordingly, so we take the extreme that choice implies.
  readonly property color barBackdrop: {
    var fg = bar ? bar.barForeground : Color.foreground
    if (bar && bar.transparent)
      return relLuminance(fg) > 0.5 ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1)
    return bar ? bar.background : Color.background
  }

  // For external strings handed to shell-owned Texts we cannot force into
  // PlainText (PanelHero's meta, which also uppercases — breaking escaped
  // entities): strip the markup-significant characters instead.
  function stripMarkup(s) {
    return String(s).replace(/[<>&]/g, " ").replace(/\s+/g, " ").trim()
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function resetText(w) {
    if (!w || !w.reset_at) return ""
    var ms = new Date(w.reset_at).getTime() - nowMs
    if (!isFinite(ms)) return ""
    return ms > 0 ? "Resets in " + formatDuration(ms) : "Resets now"
  }

  function money(cents) {
    var n = Number(cents)
    if (!isFinite(n)) n = 0
    return "$" + (n / 100).toFixed(2)
  }

  function updatedText() {
    if (!usage || !usage.updated_at) return ""
    var t = new Date(usage.updated_at)
    if (isNaN(t.getTime())) return ""
    return Qt.formatTime(t, "HH:mm")
  }

  // Freshness footer, in the house shape every widget of the family uses:
  // clock glyph, "Updated HH:MM", and a "· <status>" suffix only when the data
  // is not fresh. The waybar tooltip builds the same line from the same parts,
  // so a reader sees one footer regardless of which frontend renders it.
  function footerText() {
    if (!hasData) return loading ? "󰅐  Waiting for first usage data…" : ""
    var at = updatedText()
    if (at === "" && !stale) return ""
    return "󰅐  Updated " + (at !== "" ? at : "—")
  }

  // Rendered as its own run so it can carry the warning tint while the
  // timestamp beside it stays dim.
  function footerSuffix() {
    if (!hasData || !stale) return ""
    if (pluginStale) return " · stale (refresh failed)"
    return " · stale (" + (usage.stale_reason === "network"
      ? "waiting for network" : "API errors") + ")"
  }

  // ---------------------------------------------------------------- wiring

  // Open sweep: every panel open animates the meter fills from zero to their
  // value, uncovering the fixed color scale each meter paints (see Meter).
  // Data refreshes while the panel sits open never re-trigger it — they keep
  // the 160ms delta Behaviors. openSweeping gates those Behaviors: set BEFORE
  // the jump to 0, cleared in onFinished (not onStopped, which also fires on
  // restart() during rapid re-opens). openProgress starts at 1 so nothing
  // renders from a construction-time zero.
  property real openProgress: 1
  property bool openSweeping: false

  NumberAnimation {
    id: openSweep
    target: root
    property: "openProgress"
    from: 0
    to: 1
    duration: 200
    easing.type: Easing.OutCubic
    onFinished: root.openSweeping = false
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    openSweeping = true
    openSweep.restart()
    refresh(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The shell's base handler covers open/close/show/hide/toggle; this one adds
  // `refresh` so a keybind or a script can force a fetch without opening the
  // panel. Overriding means restating the five, so `manageIpc: false` above
  // turns the base one off and this is the only handler on the target.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh(true) }
  }

  Process {
    id: statusProc
    // A command that does not exist gives NEITHER `started` NOR `exited` —
    // Quickshell just drops `running` back to false. That is the only signal a
    // failed start emits, and without this handler the panel sits on its
    // loading text for ever: maybeFinalize() waits on processDone, which
    // nothing would ever set. This IS the first run of anyone who installed
    // the plugin from the marketplace and does not have the CLI yet.
    onRunningChanged: {
      if (running) return
      root.processDone = true
      exitFallback.restart()
      root.maybeFinalize()
    }
    onExited: function(code) {
      root.sawExit = true
      root.exitCode = code
      root.processDone = true
      // Failed-start case: the collector may never fire, so arm a fallback.
      exitFallback.restart()
      root.maybeFinalize()
    }
    stdout: StdioCollector {
      waitForEnd: true
      // A tripwire, not a limit, and it counts UTF-16 units rather than bytes —
      // QML's String.length has no byte view, so the old name and the old
      // message both claimed a bound this never measured: a megabyte of units
      // is up to three megabytes of UTF-8. StdioCollector has already buffered
      // the whole stream by the time this runs, so it cannot cap the peak
      // memory either. The real bound is in the CLI, which reads every file
      // and every response under a byte cap of its own, and three megabytes is
      // still far outside anything it can produce. What this does is refuse to
      // RETAIN an answer that could not have come from a healthy run, and say
      // so, instead of parsing megabytes of unknown text into the long-lived
      // shell process.
      readonly property int maxChars: 1024 * 1024
      onStreamFinished: {
        if (text.length > maxChars) {
          root.tripwireFired = true
          root.capturedText = ""
          root.setError(root.binName + " returned more than " + maxChars + " characters — refusing it")
        } else {
          root.capturedText = text
        }
        root.collectorDone = true
        root.maybeFinalize()
      }
    }
  }

  // The copy button shows a check for a moment.
  property bool installCopied: false
  Timer {
    id: copiedReset
    interval: 1500
    onTriggered: root.installCopied = false
  }

  Timer {
    id: exitFallback
    interval: 300
    repeat: false
    onTriggered: {
      // Give up on the collector for this run.
      root.collectorDone = true
      root.maybeFinalize()
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // Keep countdowns honest while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refresh(true)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh(true) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: Claude glyph · plan ----------
          PanelHero {
            width: parent.width
            title: "Claude"
            meta: root.usage ? root.stripMarkup(root.usage.plan || "") : (root.loading ? "Loading" : "")
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\ue861"
                color: root.brandColor
                font.family: "Font Awesome 7 Brands"
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Empty / error states ----------
          //
          // Two different situations, two different surfaces, the same two in
          // codexbar: "nothing to show yet" is a quiet centred line, while a
          // hard failure is a bordered card — a thing that went wrong deserves
          // an edge around it. An error BEHIND stale data is neither: that one
          // rides under the data it explains, at the bottom of the panel.
          Text {
            visible: !root.hasData && root.loadError === ""
            width: parent.width
            topPadding: Style.space(16)
            text: "No usage data yet.\nLog in with the claude CLI and refresh."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          BorderSurface {
            visible: !root.hasData && root.loadError !== ""
            width: parent.width
            implicitHeight: errorText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.panelColored ? root.urgent : root.foreground, 0.10)
            borderSpec: Border.flat(root.alpha(root.panelColored ? root.urgent : root.foreground, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: errorText
              anchors.left: parent.left
              anchors.right: copyInstallButton.visible ? copyInstallButton.left : parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              textFormat: Text.PlainText
              text: root.loadError
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Copies installCmd as one argv element: no shell line, no
            // trailing newline. Gated on notInstalled, never on error text.
            PanelActionButton {
              id: copyInstallButton
              visible: root.notInstalled
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              // nf-md-content_copy / nf-md-check, written literally (a "\u"
              // escape takes exactly four hex digits; these are five).
              iconText: root.installCopied ? "󰄬" : "󰆏"
              tooltipText: root.installCopied ? "Copied" : "Copy install command"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              size: Style.space(20)
              onClicked: {
                Util.execArgv(["wl-copy", root.installCmd])
                root.installCopied = true
                copiedReset.restart()
              }
            }
          }

          // ---------- Usage windows ----------
          PanelSeparator {
            visible: root.windows.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.windows.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "USAGE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.windows

              WindowSection {
                required property var modelData
                width: parent.width
                win: modelData
              }
            }
          }

          // ---------- Extra usage ----------
          PanelSeparator {
            visible: !!root.extra
            foreground: root.foreground
          }

          Column {
            id: extraSection
            visible: !!root.extra
            width: parent.width
            spacing: Style.space(6)

            readonly property bool balanceKnown: !!root.extra && root.extra.balance_known === true
            // Figure and color both read the meter's ANIMATED percentage, so
            // the number counts up with the bar and always carries the tone
            // the meter's tip has that frame.
            readonly property real shownPct: extraMeter.shownPct
            readonly property color sevColor: root.extra
              ? root.panelValueColor(shownPct)
              : root.foreground

            PanelSectionHeader {
              width: parent.width
              text: "EXTRA USAGE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(extraSpentLabel.implicitHeight, extraPercentLabel.implicitHeight)

              Text {
                id: extraSpentLabel
                text: root.extraSpentSummary
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: extraPercentLabel
                visible: extraSection.balanceKnown
                text: root.extra ? Math.round(extraSection.shownPct) + "%" : ""
                textFormat: Text.PlainText
                color: extraSection.sevColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              id: extraMeter
              visible: extraSection.balanceKnown
              width: parent.width
              pct: root.extra ? Number(root.extra.used_pct || 0) : 0
            }

            Text {
              width: parent.width
              text: root.extraCreditSummary
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // ---------- API error (behind stale data) ----------
          PanelSeparator {
            visible: !!root.apiError || (root.hasData && root.loadError !== "")
            foreground: root.foreground
          }

          // One caption line, not a heading plus a body: the code and the
          // message are one sentence about one failure, and giving the code its
          // own larger bold line made a footnote look like a section.
          Text {
            visible: !!root.apiError || (root.hasData && root.loadError !== "")
            width: parent.width
            textFormat: Text.PlainText
            text: {
              if (root.apiError) {
                var head = root.apiError.http_status !== undefined ? "HTTP " + root.apiError.http_status : ""
                var msg = String(root.apiError.message || "")
                if (head === "") return msg
                return msg !== "" ? head + " — " + msg : head
              }
              return root.hasData ? root.loadError : ""
            }
            // 5xx is the server failing; 4xx is usually something the user can
            // act on. Full urgent is reserved for the former.
            color: root.apiError && Number(root.apiError.http_status) >= 500
              ? (root.panelColored ? root.urgent : root.foreground)
              : (root.panelColored ? root.mix(root.dim, root.urgent, 0.5) : root.dim)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---- Freshness footer: when the data is from, plus an inline
          //      refresh. The button re-runs the CLI right now — the same
          //      forced refresh the bar's middle-click does — so a stale panel
          //      can be corrected without closing it, and it is disabled while
          //      a fetch is already in flight so clicks cannot queue up. The
          //      rule and the row are always shown: the button has to stay
          //      reachable exactly when there is no timestamp to print yet.
          PanelSeparator {
            foreground: root.foreground
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(footerLabel.implicitHeight, refreshButton.implicitHeight)

            Row {
              id: footerLabel
              anchors.left: parent.left
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                text: root.footerText()
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: text !== ""
                text: root.footerSuffix()
                textFormat: Text.PlainText
                color: root.freshnessWarn
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-md-refresh (U+F0450). Written literally: a JS "\\u" escape takes
              // exactly FOUR hex digits, so "\\uf0450" is U+F045 followed by a "0".
              iconText: "󰑐"
              tooltipText: "Refresh now"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              size: Style.space(20)
              enabled: !root.fetchBusy
              onClicked: root.refresh(true)
            }
          }
        }
      }
    }
  }

  // One usage window: name and percent+pacing arrow, meter with an
  // elapsed-time marker at the pace point, reset countdown and pacing text.
  component WindowSection: Column {
    id: section
    property var win: null

    readonly property var w: win ? win.w : null
    readonly property int usedPct: w ? Math.round(Number(w.used_pct || 0)) : 0
    readonly property int elapsedPct: w ? Math.round(Number(w.elapsed_pct || 0)) : 0
    readonly property var pace: w ? (w.pace || null) : null
    // Figure and color both read the meter's ANIMATED percentage rather than
    // its target, so the number counts up with the bar on open (and eases with
    // it on a refresh) and takes the ramp color at whatever value it is
    // showing — exactly the tone the meter's tip carries below it that frame,
    // so the figure reads as the point the bar has reached on the scale rather
    // than as a separate severity step. `usedPct` stays the meter's input and
    // the rounding both ends agree on, which is what makes the last frame land
    // on the real value with no jump.
    readonly property real shownPct: sectionMeter.shownPct
    readonly property color sevColor: root.panelValueColor(shownPct)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(nameLabel.implicitHeight, valueLabel.implicitHeight)

      Text {
        id: nameLabel
        text: section.win ? section.win.title : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: valueLabel.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: valueLabel
        // Just the number. The pace arrow used to be glued here, where it read
        // as a comment on the USAGE — "12% ↓" looks like the usage fell — when
        // it is really about the pace. It now sits with the pace text that
        // explains it, one line below, exactly as codexbar does.
        text: Math.round(section.shownPct) + "%"
        textFormat: Text.PlainText
        color: section.sevColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      id: sectionMeter
      width: parent.width
      pct: section.usedPct
      markerAt: section.w && section.w.reset_at ? section.elapsedPct / 100 : -1
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(resetLabel.implicitHeight, paceLabel.implicitHeight)

      Text {
        id: resetLabel
        text: root.resetText(section.w)
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: paceLabel
        // Arrow and text both come from the SIGN of the delta, so they can
        // never disagree. The ±10 tolerance band lives in `state` and paints
        // only the COLOR — saying "on pace" while the meter sits nine points
        // behind its marker made the words contradict the picture.
        text: {
          if (!section.pace) return ""
          var d = Number(section.pace.delta_points)
          if (!isFinite(d) || d === 0) return "→ on pace"
          return (d > 0 ? "↑ " : "↓ ") + String(section.pace.points_label || "")
        }
        textFormat: Text.PlainText
        color: root.paceColor(section.pace ? String(section.pace.state || "") : "")
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // Rounded track with an animated fill and an optional elapsed-time marker:
  // a thin tick at the pace point, where usage would sit if it were spent
  // evenly across the window.
  //
  // The fill paints a SPATIAL scale, not a tint: green at 0%, through amber,
  // to red at 90%+ (the gauge, see usageColor). The gradient spans the
  // fill, so each anchor's stop is rescaled by 1/fraction — an anchor at
  // `a` percent sits at `a/displayed` along the fill — and anchors past the
  // tip collapse onto 1.0 carrying the tip color. The visible result is the
  // scale's 0..displayed segment, with the tip exactly usageColor(displayed).
  // Rescaling (rather than clipping a full-width gradient) is what lets the
  // fill keep its `radius`, so its tip stays as round as the track.
  //
  // Everything is derived from `displayPct` — the fraction actually painted
  // this frame — never the static value: during the open sweep that keeps a
  // given percentage at a fixed color, so the animation reads as uncovering
  // the scale rather than stretching a compressed copy of it. The pace marker
  // rides the same `openProgress`, so fill, marker and figure sweep as one.
  //
  // The Item is taller than the track: the elapsed marker gets its own lane
  // above it (see below), and the track is centered in what is left.
  component Meter: Item {
    id: meter
    property real pct: 0
    property real markerAt: -1
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    // The fill's target width. What is actually PAINTED lags this during the
    // 160ms refresh animation, which is why the stops below read the animated
    // width instead — see meterFill.shownPct.
    readonly property real displayPct: root.clamp(pct, 0, 100) * root.openProgress

    // The percentage on screen THIS frame, for anything outside the meter that
    // has to stay in lockstep with it — the section's figure and its color.
    // One animated quantity feeds geometry, ramp and text, so the number
    // cannot drift from the bar: it is the same value, not a second animation
    // that happens to share a duration.
    readonly property real shownPct: meterFill.shownPct

    // The scale's turning points, plus a stop pinned at 100 so the last band
    // stays flat instead of being extrapolated past its anchor. Data-driven:
    // the ramp comes from the CLI, so this follows a threshold change too.
    readonly property var rampAnchors: {
      var out = []
      for (var i = 0; i < root.gaugeStops.length; i++) out.push(root.gaugeStops[i].pct)
      out.push(100)
      return out
    }
    // Anchors beyond the ramp collapse onto the tip, where they are harmless
    // duplicates — that is what lets a fixed pool of stops render any ramp.
    function anchorAt(i) {
      return i < rampAnchors.length ? rampAnchors[i] : 100
    }

    // Where a scale anchor lands along the fill, and the color it carries, for
    // the percentage currently painted. A zero-width fill (sweep start) parks
    // every stop at 0 rather than dividing by it.
    function rampStop(anchorPct, shown) {
      return shown > 0 ? Math.min(1, anchorPct / shown) : 0
    }
    function rampColor(anchorPct, shown) {
      return root.panelValueColor(Math.min(anchorPct, shown))
    }

    implicitHeight: Style.space(14)

    Rectangle {
      id: meterTrack
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: meter.thickness
      radius: height / 2
      color: root.track
    }

    Rectangle {
      id: meterFill
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * meter.displayPct / 100

      // The percentage actually on screen this frame, read back off the
      // animated width. Deriving the stops from this rather than from the
      // target is what keeps the scale pinned during BOTH animations: while a
      // refresh eases the width from 40% to 70%, the colors under it stay put
      // instead of jumping to the new value's ramp.
      readonly property real shownPct: meterTrack.width > 0
        ? width / meterTrack.width * 100 : 0

      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop {
          position: meter.rampStop(meter.anchorAt(0), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(0), meterFill.shownPct)
        }
        GradientStop {
          position: meter.rampStop(meter.anchorAt(1), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(1), meterFill.shownPct)
        }
        GradientStop {
          position: meter.rampStop(meter.anchorAt(2), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(2), meterFill.shownPct)
        }
        GradientStop {
          position: meter.rampStop(meter.anchorAt(3), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(3), meterFill.shownPct)
        }
        GradientStop {
          position: meter.rampStop(meter.anchorAt(4), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(4), meterFill.shownPct)
        }
        GradientStop {
          position: meter.rampStop(meter.anchorAt(5), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(5), meterFill.shownPct)
        }
        GradientStop {
          position: meter.rampStop(meter.anchorAt(6), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(6), meterFill.shownPct)
        }
        GradientStop {
          position: meter.rampStop(meter.anchorAt(7), meterFill.shownPct)
          color: meter.rampColor(meter.anchorAt(7), meterFill.shownPct)
        }
      }

      Behavior on width {
        // Delta refreshes ease over 160ms; the open sweep drives width
        // per-frame itself, so the Behavior stands aside while it runs.
        enabled: !root.openSweeping
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    // The pace marker: where usage would sit if the window were spent evenly.
    //
    // Rides ABOVE the track, never across it. The marker sits at the ELAPSED
    // position, which lands on the fill when usage runs ahead of pace and on
    // the empty track when it runs behind — no single tone holds contrast
    // against both, and drawn over the fill it reads as a seam in the bar
    // rather than as a mark. Outside the track it always meets the panel
    // background, so its contrast is constant, the fill stays unbroken, and it
    // can never be mistaken for the fill's tip.
    Rectangle {
      id: paceMarker
      visible: meter.markerAt >= 0
      width: Math.max(2, Style.spaceReal(2))
      height: Math.max(3, Style.spaceReal(4))
      anchors.bottom: meterTrack.top
      anchors.bottomMargin: Math.max(1, Style.spaceReal(1))

      // Travels with the fill and the figure: all three are scaled by the same
      // openProgress, so the sweep moves them as one — and scaling POSITION
      // rather than reading the fill's width is what keeps a window with 0%
      // used but 60% elapsed working, where the fill has no width to read.
      // The Behavior is gated like the fill's, or the 160ms ease would fight
      // the per-frame sweep and leave the marker trailing the bar.
      x: root.clamp(meterTrack.width * root.clamp(meter.markerAt, 0, 1) * root.openProgress
                      - width / 2,
                    0, Math.max(0, meterTrack.width - width))
      color: root.alpha(root.foreground, 0.75)

      Behavior on x {
        enabled: !root.openSweeping
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}

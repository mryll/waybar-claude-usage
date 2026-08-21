import QtQuick
import qs.Commons
import qs.Ui

// Omarchy shell bar widget for claudebar. Thin host following the first-party
// weather plugin's pattern: the button lives here, all data and the detail
// panel live in Panel.qml (loaded once, shared identity for the bar's popout
// coordinator).
BarWidget {
  id: root
  moduleName: "mryll.claudebar"
  readonly property string brandIcon: "\ue861"
  readonly property string barLabel: panelLoader.item ? panelLoader.item.barLabel : ""
  readonly property string plainText: brandIcon + (barLabel !== "" ? " " + barLabel : "")

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item) panelLoader.item.refresh(false)
  }

  function refreshForce() {
    if (panelLoader.item) panelLoader.item.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  // Shape contract for shell summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (Bar.requestPopout prefers closeForPopoutSwitch over close).
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // How wide the bar's open-panel underline should be. Without this hint the bar
  // falls back to 55% of the SLOT, which reads as a dot under a narrow widget
  // but as a bar that visibly stops short under a wide one. The painted content
  // is the honest extent, so the mark tracks what the widget draws instead of a
  // fraction of the box it happens to sit in. (Same hint the first-party clock
  // gives; it passes its label width.)
  // Extent of the open-panel mark, and the width the content row is centered
  // against. The bar computes the mark as
  //     width = Math.round(hint);  x = Math.round((slot.width - width) / 2)
  // so the row must be centered with the SAME rounded width and the SAME
  // formula. Letting `anchors.centerIn` center the row against its own
  // fractional implicitWidth instead puts the two on different pixels whenever
  // the slot width is fractional (it usually is: font metrics are not integers),
  // and the mark reads as shifted under the text.
  readonly property real markExtent: Math.round(contentRow.implicitWidth)
  readonly property real openPanelIndicatorWidth: markExtent

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.plainText
    labelVisible: false
    fixedWidth: root.vertical ? -1 : contentRow.implicitWidth + button.scaledHorizontalMargin * 2
    foreground: panelLoader.item ? panelLoader.item.barColor
      : (root.bar ? root.bar.barForeground : Color.foreground)
    // Degradation is expressed in barColor (a blend toward the muted shade),
    // never by dimming the button: WidgetButton.dimmed drops the whole face to
    // 45% opacity, which made the glyph go visibly dark every time the API
    // answered 429 and back again on the next poll. The bar face now degrades
    // the same way codexbar's does.
    // The panel is the detail view, so the bar face normally carries no
    // tooltip. The one exception is the alarm dot: a 4px mark can't say what
    // it is about, so while it shows, hovering names the window that is maxed
    // out. Empty string the rest of the time — no dot, no tooltip.
    tooltipText: panelLoader.item ? panelLoader.item.alarmTooltip : ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refreshForce()
      else if (b === Qt.RightButton) {
        if (root.bar) root.bar.run("xdg-open https://claude.ai/settings/usage")
      } else root.togglePanel()
    }

    Row {
      id: contentRow
      x: Math.round((parent.width - root.markExtent) / 2)
      anchors.verticalCenter: parent.verticalCenter
      spacing: label.visible ? Style.spacing.labelGap : 0

      Text {
        text: root.brandIcon
        textFormat: Text.PlainText
        color: button.foreground
        font.family: "Font Awesome 7 Brands"
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        id: label
        visible: root.barLabel !== ""
        text: root.barLabel
        textFormat: Text.PlainText
        color: button.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
      }


      // Serving cached data — the same ⏸ the CLI appends to the waybar bar text.
      // A mark, not a tint: the number keeps the ramp color of its own value, so
      // the bar and the panel never show one percentage in two colors. Hovering
      // the widget says what it means.
      Text {
        visible: panelLoader.item ? panelLoader.item.barStale === true : false
        // nf-fa-pause, not U+23F8: the Unicode pause resolves to the COLOR
        // emoji glyph here, which paints its own orange and ignores the theme
        // tone this mark is supposed to wear. U+FE0E does not help — the font
        // stack has no text-presentation glyph for it. The CLI emits the same
        // Nerd glyph in the waybar bar text.
        text: "\uf04c"
        textFormat: Text.PlainText
        color: Qt.darker(button.foreground, 1.55)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Math.round(button.fontSize * 0.85)
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }

      // A window other than the one on the bar is maxed out. The label's color
      // belongs to the number it shows, so the alarm gets its own mark instead
      // of recoloring that number — a dot small enough to read as punctuation.
      Rectangle {
        id: alarmDot
        visible: panelLoader.item ? panelLoader.item.otherWindowCritical === true : false
        width: Math.max(3, Math.round(button.fontSize * 0.32))
        height: width
        radius: width / 2
        // Monochrome bar keeps the mark — it is the alarm, not decoration —
        // but paints it in the same foreground as the label.
        color: panelLoader.item && panelLoader.item.barMono === true
          ? button.foreground
          : (root.bar ? root.bar.urgent : Color.urgent)
        anchors.verticalCenter: parent.verticalCenter
        // Sits just above the text's midline, where a degree sign would go.
        anchors.verticalCenterOffset: -Math.round(button.fontSize * 0.28)
      }
    }
  }
}

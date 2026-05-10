// Field'o'Meter Plugin for QField
// Geological strike/dip/plunge measurement with averaging, outlier rejection,
// calibration checks, and auto-fill of feature form attributes.
//
// Based in part on swaxi/compass (open source, github.com/swaxi/compass)
// Significant rewrites: sampling window, outlier rejection, calibration UI,
// magnetic interference detection, tilt-instability warnings, settings persistence.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtSensors
import Qt.labs.settings
import org.qfield

Item {
    id: root

    // ------------------------------------------------------------------
    // PERSISTENT SETTINGS
    // ------------------------------------------------------------------
    Settings {
        id: settings
        category: "FieldoMeterPlugin"
        property real magneticDeclination: 0.0
        property bool southernHemisphere: false
        property int sampleDurationMs: 2000
        property bool autoFillEnabled: true
    }

    // ------------------------------------------------------------------
    // QFIELD HOOKS
    // ------------------------------------------------------------------
    property var mainWindow: iface.mainWindow()
    property var overlayFeatureFormDrawer: iface.findItemByObjectName('overlayFeatureFormDrawer')

    // ------------------------------------------------------------------
    // SENSORS
    // ------------------------------------------------------------------
    Compass {
        id: compass
        active: true
        dataRate: 50      // poll fast for averaging
        property real currentAzimuth: 0
        property real currentCalibration: -1   // 0..1, -1 = unknown
        onReadingChanged: {
            if (reading) {
                currentAzimuth = reading.azimuth
                if (reading.calibrationLevel !== undefined)
                    currentCalibration = reading.calibrationLevel
            }
        }
    }

    Accelerometer {
        id: accelerometer
        active: true
        dataRate: 50
        property real currentX: 0
        property real currentY: 0
        property real currentZ: 0
        onReadingChanged: {
            if (reading) {
                currentX = reading.x
                currentY = reading.y
                currentZ = reading.z
            }
        }
    }

    Magnetometer {
        id: magnetometer
        active: true
        dataRate: 50
        returnGeoValues: true
        property real currentMagnitude: 0   // microtesla
        onReadingChanged: {
            if (reading) {
                var mx = reading.x
                var my = reading.y
                var mz = reading.z
                // Qt Magnetometer returns values in Tesla; convert to microtesla
                currentMagnitude = Math.sqrt(mx*mx + my*my + mz*mz) * 1e6
            }
        }
    }

    // ------------------------------------------------------------------
    // SAMPLING STATE
    // ------------------------------------------------------------------
    property bool isSampling: false
    property var sampleBuffer: []           // array of {dip, dipDir, strike, plunge, az}
    property var lastResult: null           // last frozen reading with stats
    property int sampleStartTime: 0
    property bool warnedInterference: false

    // ------------------------------------------------------------------
    // CORE GEOMETRY
    // Compute strike / dip / dip-direction from gravity + compass azimuth.
    // ------------------------------------------------------------------
    function computeReading(gx, gy, gz, azimuth) {
        var g_mag = Math.sqrt(gx*gx + gy*gy + gz*gz)
        if (g_mag < 1.0) return null

        gx /= g_mag; gy /= g_mag; gz /= g_mag

        // Dip = angle of phone's screen plane from horizontal
        var dip = Math.acos(Math.abs(gz)) * 180 / Math.PI

        // Transform horizontal gravity component into world frame using azimuth
        var azRad = azimuth * Math.PI / 180
        var g_north = gy * Math.cos(azRad) - gx * Math.sin(azRad)
        var g_east  = gy * Math.sin(azRad) + gx * Math.cos(azRad)

        var dipDirection = Math.atan2(g_east, g_north) * 180 / Math.PI
        dipDirection += settings.magneticDeclination
        if (settings.southernHemisphere) dipDirection = (dipDirection + 180) % 360
        if (dipDirection < 0) dipDirection += 360
        if (dipDirection >= 360) dipDirection -= 360

        var strike = dipDirection - 90
        if (strike < 0) strike += 360

        // Plunge = tilt of phone's long (Y) axis from horizontal
        var plunge = Math.asin(Math.max(-1, Math.min(1, Math.abs(gy)))) * 180 / Math.PI

        var correctedAz = azimuth + settings.magneticDeclination
        if (settings.southernHemisphere) correctedAz = (correctedAz + 180) % 360
        if (correctedAz < 0) correctedAz += 360
        if (correctedAz >= 360) correctedAz -= 360

        return {
            dip: dip,
            dipDirection: dipDirection,
            strike: strike,
            plunge: plunge,
            azimuth: correctedAz
        }
    }

    function currentReading() {
        return computeReading(
            accelerometer.currentX,
            accelerometer.currentY,
            accelerometer.currentZ,
            compass.currentAzimuth
        )
    }

    // ------------------------------------------------------------------
    // SAMPLING — collect over a window, reject outliers, compute stats
    // ------------------------------------------------------------------
    Timer {
        id: sampleTimer
        interval: 20    // 50 Hz
        repeat: true
        onTriggered: {
            var r = currentReading()
            if (r) sampleBuffer.push(r)

            if (Date.now() - sampleStartTime >= settings.sampleDurationMs) {
                stop()
                finishSampling()
            }
        }
    }

    function startSampling() {
        if (isSampling) return
        sampleBuffer = []
        warnedInterference = false
        isSampling = true
        sampleStartTime = Date.now()

        // Magnetic interference check at start
        if (magnetometer.currentMagnitude > 0 &&
           (magnetometer.currentMagnitude < 25 || magnetometer.currentMagnitude > 65)) {
            mainWindow.displayToast("⚠ Magnetic interference (" +
                Math.round(magnetometer.currentMagnitude) + " µT). Move away from metal.")
            warnedInterference = true
        }

        // Calibration check
        if (compass.currentCalibration >= 0 && compass.currentCalibration < 0.5) {
            mainWindow.displayToast("⚠ Compass uncalibrated. Wave phone in figure-8.")
        }

        sampleTimer.start()
    }

    function median(arr) {
        if (arr.length === 0) return 0
        var s = arr.slice().sort(function(a,b){ return a-b })
        var m = Math.floor(s.length/2)
        return (s.length % 2) ? s[m] : (s[m-1]+s[m])/2
    }

    function stdev(arr, mean) {
        if (arr.length < 2) return 0
        var sum = 0
        for (var i=0; i<arr.length; i++) sum += (arr[i]-mean)*(arr[i]-mean)
        return Math.sqrt(sum / (arr.length - 1))
    }

    // Circular mean for angles 0..360
    function circularMedian(arr) {
        if (arr.length === 0) return 0
        // Convert to unit vectors, take component median, convert back
        var xs = [], ys = []
        for (var i=0; i<arr.length; i++) {
            var r = arr[i] * Math.PI / 180
            xs.push(Math.cos(r))
            ys.push(Math.sin(r))
        }
        var mx = median(xs), my = median(ys)
        var deg = Math.atan2(my, mx) * 180 / Math.PI
        if (deg < 0) deg += 360
        return deg
    }

    function circularStdev(arr, meanDeg) {
        if (arr.length < 2) return 0
        // Mean of squared shortest angular distances
        var sum = 0
        for (var i=0; i<arr.length; i++) {
            var d = arr[i] - meanDeg
            while (d > 180) d -= 360
            while (d < -180) d += 360
            sum += d*d
        }
        return Math.sqrt(sum / (arr.length - 1))
    }

    function finishSampling() {
        isSampling = false
        if (sampleBuffer.length < 5) {
            mainWindow.displayToast("✗ Not enough samples. Hold steady and retry.")
            return
        }

        // Trim 10% from each end (outlier rejection on dip — most stable axis)
        var trimCount = Math.floor(sampleBuffer.length * 0.10)
        var sortedByDip = sampleBuffer.slice().sort(function(a,b){ return a.dip - b.dip })
        var trimmed = sortedByDip.slice(trimCount, sortedByDip.length - trimCount)

        // Extract per-axis arrays
        var dips = [], strikes = [], dipDirs = [], plunges = [], azs = []
        for (var i=0; i<trimmed.length; i++) {
            dips.push(trimmed[i].dip)
            strikes.push(trimmed[i].strike)
            dipDirs.push(trimmed[i].dipDirection)
            plunges.push(trimmed[i].plunge)
            azs.push(trimmed[i].azimuth)
        }

        var dipMed = median(dips)
        var strikeMed = circularMedian(strikes)
        var dipDirMed = circularMedian(dipDirs)
        var plungeMed = median(plunges)
        var azMed = circularMedian(azs)

        var dipStd = stdev(dips, dipMed)
        var strikeStd = circularStdev(strikes, strikeMed)
        var dipDirStd = circularStdev(dipDirs, dipDirMed)

        // Tilt-instability warning
        var unstable = (dipMed < 5 || dipMed > 85)

        lastResult = {
            dip: dipMed,
            strike: strikeMed,
            dipDirection: dipDirMed,
            plunge: plungeMed,
            azimuth: azMed,
            dipStd: dipStd,
            strikeStd: strikeStd,
            dipDirStd: dipDirStd,
            unstable: unstable,
            sampleCount: trimmed.length
        }

        // Auto-fill if form is open
        if (settings.autoFillEnabled && overlayFeatureFormDrawer && overlayFeatureFormDrawer.visible) {
            tryAutoFill(lastResult)
        }

        // Show review dialog
        reviewDialog.open()
    }

    // ------------------------------------------------------------------
    // AUTO-FILL FEATURE FORM
    // ------------------------------------------------------------------
    function tryAutoFill(r) {
        try {
            if (!overlayFeatureFormDrawer || !overlayFeatureFormDrawer.visible) return false
            if (!overlayFeatureFormDrawer.featureModel) return false
            var feature = overlayFeatureFormDrawer.featureModel.feature
            if (!feature) return false

            var fieldNames = feature.fields.names
            var populated = false

            for (var i = 0; i < fieldNames.length; i++) {
                var fn = fieldNames[i].toLowerCase()
                if (fn === 'fid' || fn === 'id' || fn === 'objectid') continue

                if (fn === 'azimuth' || fn === 'azimut' || fn === 'heading') {
                    feature.setAttribute(i, Math.round(r.azimuth)); populated = true
                }
                else if (fn === 'dip' || fn === 'dip_angle' || fn === 'pendage' || fn === 'dip_ref') {
                    feature.setAttribute(i, Math.round(r.dip)); populated = true
                }
                else if (fn === 'dip_direction' || fn === 'dipdirection' || fn === 'dip_dir' || fn === 'dipdir_ref') {
                    feature.setAttribute(i, Math.round(r.dipDirection)); populated = true
                }
                else if (fn === 'strike' || fn === 'strike_rhr' || fn === 'strike_ref') {
                    feature.setAttribute(i, Math.round(r.strike)); populated = true
                }
                else if (fn === 'plunge' || fn === 'plongement') {
                    feature.setAttribute(i, Math.round(r.plunge)); populated = true
                }
                else if (fn === 'dip_err' || fn === 'dip_uncertainty') {
                    feature.setAttribute(i, Math.round(r.dipStd * 10) / 10); populated = true
                }
                else if (fn === 'strike_err' || fn === 'strike_uncertainty') {
                    feature.setAttribute(i, Math.round(r.strikeStd * 10) / 10); populated = true
                }
            }

            if (populated) {
                overlayFeatureFormDrawer.featureModel.feature = feature
                return true
            }
        } catch (e) {
            console.log("FieldoMeter autofill error: " + e)
        }
        return false
    }

    // ------------------------------------------------------------------
    // UI: TOOLBAR BUTTON
    // Live readout while idle. Tap to sample. Long-press for settings.
    // ------------------------------------------------------------------
    Component {
        id: toolbarButton
        Button {
            id: tbBtn
            width: 96
            height: 150

            // Status colour: green = good, yellow = caution, red = bad
            function statusColor() {
                if (isSampling) return "#1976D2"
                if (compass.currentCalibration >= 0 && compass.currentCalibration < 0.3) return "#D32F2F"
                if (compass.currentCalibration >= 0 && compass.currentCalibration < 0.7) return "#F57C00"
                if (magnetometer.currentMagnitude > 0 &&
                   (magnetometer.currentMagnitude < 25 || magnetometer.currentMagnitude > 65)) return "#F57C00"
                return "#388E3C"
            }

            background: Rectangle {
                color: tbBtn.pressed ? Qt.darker(tbBtn.statusColor(), 1.3) : tbBtn.statusColor()
                radius: 8
                border.color: "#212121"
                border.width: 2

                // Auto-fill indicator
                Rectangle {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 4
                    width: 22; height: 22; radius: 11
                    color: settings.autoFillEnabled ? "#FFEB3B" : "#9E9E9E"
                    border.color: "white"; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: settings.autoFillEnabled ? "A" : "M"
                        font.pixelSize: 11; font.bold: true
                        color: "#212121"
                    }
                }
            }

            contentItem: Column {
                anchors.centerIn: parent
                spacing: 2
                Text {
                    text: isSampling ? "⏱" : "🧭"
                    font.pixelSize: 22
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: "Field'o'Meter"
                    font.pixelSize: 8; font.bold: true
                    color: "white"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Rectangle { width: 80; height: 1; color: "white"; opacity: 0.3
                    anchors.horizontalCenter: parent.horizontalCenter }
                Text {
                    text: {
                        if (isSampling) return "Sampling..."
                        var r = currentReading()
                        return r ? "Str " + Math.round(r.strike) + "°" : "—"
                    }
                    font.pixelSize: 11; font.bold: true; color: "white"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: {
                        if (isSampling) return ""
                        var r = currentReading()
                        return r ? "Dip " + Math.round(r.dip) + "°" : ""
                    }
                    font.pixelSize: 11; font.bold: true; color: "white"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: {
                        if (isSampling) return ""
                        var r = currentReading()
                        return r ? "Dir " + Math.round(r.dipDirection) + "°" : ""
                    }
                    font.pixelSize: 11; font.bold: true; color: "white"
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            onClicked: startSampling()
            onPressAndHold: settingsDialog.open()

            // Refresh live readout 10x/sec
            Timer {
                interval: 100; running: true; repeat: true
                onTriggered: tbBtn.contentItemChanged()
            }
        }
    }

    // ------------------------------------------------------------------
    // REVIEW DIALOG — shown after a sample completes
    // ------------------------------------------------------------------
    Dialog {
        id: reviewDialog
        title: "Reading Captured"
        modal: true
        anchors.centerIn: parent
        width: Math.min(parent ? parent.width * 0.9 : 360, 400)

        contentItem: ColumnLayout {
            spacing: 8

            Text {
                visible: lastResult && lastResult.unstable
                text: "⚠ Near horizontal/vertical — dip direction unstable"
                color: "#F57C00"; font.pixelSize: 12; font.bold: true
                Layout.fillWidth: true; wrapMode: Text.Wrap
            }

            GridLayout {
                columns: 3
                columnSpacing: 12; rowSpacing: 6
                Layout.fillWidth: true

                Text { text: "Strike"; font.bold: true }
                Text { text: lastResult ? Math.round(lastResult.strike) + "°" : "—"
                       font.pixelSize: 16; color: "#1976D2" }
                Text { text: lastResult ? "± " + lastResult.strikeStd.toFixed(1) + "°" : ""
                       color: "#666"; font.pixelSize: 11 }

                Text { text: "Dip"; font.bold: true }
                Text { text: lastResult ? Math.round(lastResult.dip) + "°" : "—"
                       font.pixelSize: 16; color: "#1976D2" }
                Text { text: lastResult ? "± " + lastResult.dipStd.toFixed(1) + "°" : ""
                       color: "#666"; font.pixelSize: 11 }

                Text { text: "Dip Dir"; font.bold: true }
                Text { text: lastResult ? Math.round(lastResult.dipDirection) + "°" : "—"
                       font.pixelSize: 16; color: "#1976D2" }
                Text { text: lastResult ? "± " + lastResult.dipDirStd.toFixed(1) + "°" : ""
                       color: "#666"; font.pixelSize: 11 }

                Text { text: "Plunge"; font.bold: true }
                Text { text: lastResult ? Math.round(lastResult.plunge) + "°" : "—"
                       font.pixelSize: 14 }
                Text { text: "" }

                Text { text: "Azimuth"; font.bold: true }
                Text { text: lastResult ? Math.round(lastResult.azimuth) + "°" : "—"
                       font.pixelSize: 14 }
                Text { text: "" }
            }

            Text {
                text: lastResult ? "Samples: " + lastResult.sampleCount : ""
                color: "#666"; font.pixelSize: 10
            }
        }

        footer: DialogButtonBox {
            Button {
                text: "Retake"
                onClicked: { reviewDialog.close(); startSampling() }
            }
            Button {
                text: "Apply"
                highlighted: true
                onClicked: {
                    if (lastResult) tryAutoFill(lastResult)
                    reviewDialog.close()
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // SETTINGS DIALOG (long-press toolbar button)
    // ------------------------------------------------------------------
    Dialog {
        id: settingsDialog
        title: "Field'o'Meter Settings"
        modal: true
        anchors.centerIn: parent
        width: Math.min(parent ? parent.width * 0.9 : 360, 420)

        contentItem: ColumnLayout {
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                Text { text: "Magnetic declination (°)"; Layout.fillWidth: true }
                TextField {
                    id: declField
                    text: settings.magneticDeclination.toString()
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    Layout.preferredWidth: 80
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Text { text: "Sample duration (ms)"; Layout.fillWidth: true }
                TextField {
                    id: durationField
                    text: settings.sampleDurationMs.toString()
                    inputMethodHints: Qt.ImhDigitsOnly
                    Layout.preferredWidth: 80
                }
            }

            CheckBox {
                id: hemiBox
                text: "Southern hemisphere"
                checked: settings.southernHemisphere
            }

            CheckBox {
                id: autoFillBox
                text: "Auto-fill feature form"
                checked: settings.autoFillEnabled
            }

            Text {
                text: "Live status:"
                font.bold: true
                Layout.topMargin: 6
            }
            Text {
                text: "Compass calibration: " +
                      (compass.currentCalibration < 0 ? "unknown" :
                       (compass.currentCalibration < 0.3 ? "POOR — calibrate now" :
                        compass.currentCalibration < 0.7 ? "fair" : "good"))
                color: compass.currentCalibration < 0.3 && compass.currentCalibration >= 0 ? "#D32F2F" : "#333"
                font.pixelSize: 11
            }
            Text {
                text: "Magnetic field: " +
                      (magnetometer.currentMagnitude > 0 ?
                        magnetometer.currentMagnitude.toFixed(1) + " µT " +
                        (magnetometer.currentMagnitude < 25 || magnetometer.currentMagnitude > 65 ?
                            "(interference!)" : "(normal)") :
                        "—")
                color: (magnetometer.currentMagnitude > 0 &&
                       (magnetometer.currentMagnitude < 25 || magnetometer.currentMagnitude > 65)) ?
                       "#D32F2F" : "#333"
                font.pixelSize: 11
            }
        }

        footer: DialogButtonBox {
            Button {
                text: "Cancel"
                onClicked: settingsDialog.close()
            }
            Button {
                text: "Save"
                highlighted: true
                onClicked: {
                    var d = parseFloat(declField.text)
                    if (!isNaN(d)) settings.magneticDeclination = d
                    var dur = parseInt(durationField.text)
                    if (!isNaN(dur) && dur >= 500 && dur <= 10000) settings.sampleDurationMs = dur
                    settings.southernHemisphere = hemiBox.checked
                    settings.autoFillEnabled = autoFillBox.checked
                    settingsDialog.close()
                    mainWindow.displayToast("✓ Settings saved")
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // INIT
    // ------------------------------------------------------------------
    Component.onCompleted: {
        Qt.callLater(function() {
            overlayFeatureFormDrawer = iface.findItemByObjectName('overlayFeatureFormDrawer')
            var btn = toolbarButton.createObject(root)
            if (btn) iface.addItemToPluginsToolbar(btn)
            mainWindow.displayToast("Field'o'Meter ready")
        })
    }
}

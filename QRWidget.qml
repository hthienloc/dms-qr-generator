import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.FileBrowser
import "./dms-common"


PluginComponent {
    id: pluginRoot

    readonly property bool clearQrOnClose: pluginData.clearQrOnClose ?? true
    readonly property string pillStyle: pluginData.pillStyle || "icon"
    readonly property string qrSize: pluginData.qrSize || "6"
    readonly property bool showHints: pluginData.showHints ?? true
    
    // Free-text input content, and the target of explicit actions (Wi-Fi share,
    // clipboard paste, drag-drop, screenshot scan). Bound to the manual field.
    property string currentText: ""
    // Exact string encoded by the currently displayed QR (set once generation
    // succeeds). SVG export uses this so it stays WYSIWYG like the PNG path.
    property string renderedText: ""
    // Single source of truth for which input owns the one QR output:
    // "text" | "contact" | "event" | "". resolveQR() (in the popout) uses it so
    // the inputs never clobber each other -- a filled template outranks the
    // free-text field, so typing there can't overwrite a contact/event QR.
    property string activeSource: ""
    property string pendingPayload: ""
    property bool isFetchingWifi: false
    property var manualInputInput: null
    property var activePopoutReference: null
    property bool hasResult: false
    property bool isSaving: false
    property bool isDecoding: false
    property string droppedImagePath: ""

    // Dual-buffering to prevent flickering
    property bool useImageA: true
    property string pathA: "/tmp/dms-qr-a.png"
    property string pathB: "/tmp/dms-qr-b.png"
    property string sourceA: ""
    property string sourceB: ""

    Timer {
        id: genTimer
        interval: 200
        repeat: false
        onTriggered: pluginRoot.generateQRInternal(pluginRoot.pendingPayload)
    }

    function clearQR() {
        currentText = "";
        renderedText = "";
        activeSource = "";
        pendingPayload = "";
        sourceA = "";
        sourceB = "";
        hasResult = false;
        droppedImagePath = "";
        if (manualInputInput) manualInputInput.text = "";
    }

    function decodeQR(path) {
        if (!path) return;
        
        let cleanPath = path;
        if (cleanPath.startsWith("file://")) {
            cleanPath = cleanPath.substring(7);
        } else if (cleanPath.startsWith("file: ")) {
            cleanPath = cleanPath.substring(6);
        }

        pluginRoot.isDecoding = true;
        pluginRoot.droppedImagePath = "file://" + cleanPath;
        
        Proc.runCommand(
            "decode-qr",
            ["zbarimg", "--raw", "-q", cleanPath],
            (stdout, exitCode) => {
                pluginRoot.isDecoding = false;
                if (exitCode === 0 && stdout.trim() !== "") {
                    pluginRoot.generateText(stdout.trim());
                } else {
                    pluginRoot.droppedImagePath = "";
                    ToastService.showError("Failed to decode QR code.");
                }
            },
            0
        );
    }

    // Single debounced generator. resolveQR() (in the popout) and generateText()
    // funnel everything through here, so the dual buffer never has two writers.
    function generate(payload) {
        pluginRoot.pendingPayload = payload;
        genTimer.restart();
    }

    function clearResult() {
        genTimer.stop();
        pluginRoot.sourceA = "";
        pluginRoot.sourceB = "";
        pluginRoot.hasResult = false;
        pluginRoot.renderedText = "";
    }

    // Explicit text actions (Wi-Fi, paste, drag-drop, scan) force the text source,
    // overriding template priority, and mirror the value into the text field.
    function generateText(text) {
        pluginRoot.currentText = text;
        pluginRoot.activeSource = "text";
        if (pluginRoot.manualInputInput)
            pluginRoot.manualInputInput.text = text;
        if (!text || text.trim() === "") {
            pluginRoot.clearResult();
            return;
        }
        pluginRoot.generate(text);
    }

    function generateQRInternal(text) {
        if (!text) return;
        const trimmed = text.trim();
        if (trimmed === "") return;
        
        // Generate to the "inactive" path
        const targetPath = pluginRoot.useImageA ? pluginRoot.pathB : pluginRoot.pathA;
        
        Proc.runCommand(
            "generate-qr",
            // "--" stops qrencode's option parsing so text starting with a dash
            // (e.g. "-h", "-V") is encoded literally instead of treated as a flag.
            ["qrencode", "-s", pluginRoot.qrSize, "-o", targetPath, "--", trimmed],
            (stdout, exitCode) => {
                if (exitCode === 0) {
                    const newSource = "file://" + targetPath + "?t=" + Date.now();
                    if (pluginRoot.useImageA) {
                        pluginRoot.sourceB = newSource;
                    } else {
                        pluginRoot.sourceA = newSource;
                    }
                    pluginRoot.renderedText = trimmed;
                    pluginRoot.hasResult = true;
                } else {
                    if (stdout && stdout.includes("not found")) {
                        ToastService.showError("qrencode is not installed. Please install it.");
                    } else {
                        ToastService.showError("Failed to generate QR code.");
                    }
                }
            },
            0
        )
    }

    // Escape a value for vCard 3.0 / iCalendar TEXT fields (RFC 2426 / 5545):
    // backslash, semicolon, comma and newline must be backslash-escaped.
    function icalEscape(value) {
        if (value === undefined || value === null) return "";
        return String(value)
            .replace(/\\/g, "\\\\")
            .replace(/;/g, "\\;")
            .replace(/,/g, "\\,")
            .replace(/\r\n|\r|\n/g, "\\n");
    }

    function buildVCard(name, phone, email, org, url) {
        const lines = ["BEGIN:VCARD", "VERSION:3.0"];
        const fn = name.trim();
        // N is required in vCard 3.0; put the whole name in the family slot.
        lines.push("N:" + icalEscape(fn) + ";;;;");
        lines.push("FN:" + icalEscape(fn));
        if (org.trim() !== "")   lines.push("ORG:" + icalEscape(org.trim()));
        if (phone.trim() !== "") lines.push("TEL;TYPE=CELL:" + icalEscape(phone.trim()));
        if (email.trim() !== "") lines.push("EMAIL;TYPE=INTERNET:" + icalEscape(email.trim()));
        if (url.trim() !== "")   lines.push("URL:" + icalEscape(url.trim()));
        lines.push("END:VCARD");
        return lines.join("\n");
    }

    // Combine date "YYYY-MM-DD" + time "HH:MM" into a floating local iCal stamp
    // "YYYYMMDDTHHMMSS". Returns "" if the date has no digits.
    function icalStamp(date, time) {
        const d = (date || "").replace(/[^0-9]/g, "");
        if (d.length < 8) return "";
        const t = ((time || "").replace(/[^0-9]/g, "") + "000000").slice(0, 6);
        return d.slice(0, 8) + "T" + t;
    }

    // Current UTC time as an iCal UTC stamp "YYYYMMDDTHHMMSSZ" (for DTSTAMP).
    function icalNow() {
        const d = new Date();
        const p = n => (n < 10 ? "0" : "") + n;
        return "" + d.getUTCFullYear() + p(d.getUTCMonth() + 1) + p(d.getUTCDate())
            + "T" + p(d.getUTCHours()) + p(d.getUTCMinutes()) + p(d.getUTCSeconds()) + "Z";
    }

    function buildEvent(title, location, startDate, startTime, endDate, endTime) {
        const lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//dms-qr-generator//EN", "BEGIN:VEVENT"];
        // UID and DTSTAMP are REQUIRED for a valid VEVENT (RFC 5545 3.6.1).
        lines.push("UID:" + Date.now() + "@dms-qr-generator");
        lines.push("DTSTAMP:" + icalNow());
        lines.push("SUMMARY:" + icalEscape(title.trim()));
        if (location.trim() !== "") lines.push("LOCATION:" + icalEscape(location.trim()));
        // DTSTART is REQUIRED (no METHOD); DTEND is only valid alongside DTSTART.
        const start = icalStamp(startDate, startTime);
        const end = icalStamp(endDate, endTime);
        if (start !== "") {
            lines.push("DTSTART:" + start);
            if (end !== "") lines.push("DTEND:" + end);
        }
        lines.push("END:VEVENT", "END:VCALENDAR");
        return lines.join("\n");
    }

    function saveImage(format) {
        if (!pluginRoot.hasResult) return;
        saveBrowserModal.saveFormat = (format === "svg") ? "svg" : "png";
        const activePath = pluginRoot.useImageA ? pluginRoot.pathA : pluginRoot.pathB;
        saveBrowserModal.activePath = activePath;
        isSaving = true;
        pluginRoot.closePopout();
        saveBrowserModal.open();
    }

    FileBrowserModal {
        id: saveBrowserModal
        browserTitle: saveFormat === "svg" ? "Save QR (SVG)" : "Save QR Image"
        browserIcon: "save"
        saveMode: true
        defaultFileName: "qr_" + new Date().toISOString().replace(/[:.T]/g, '-').replace(/-/g, '').slice(0, 12) + "." + saveFormat
        fileExtensions: saveFormat === "svg" ? ["*.svg"] : ["*.png"]

        property string activePath: ""
        property string saveFormat: "png"

        onFileSelected: filePath => {
            isSaving = true;
            let destPath = filePath;
            if (destPath.startsWith("file://")) {
                destPath = destPath.substring(7);
            } else if (destPath.startsWith("file: ")) {
                destPath = destPath.substring(6);
            }

            const onDone = (stdout, exitCode) => {
                isSaving = false;
                if (exitCode === 0) {
                    ToastService.showInfo("Saved successfully!");
                } else {
                    ToastService.showError("Failed to save image.");
                }
            };

            if (saveFormat === "svg") {
                // SVG is vector: re-render at full quality straight to the target.
                // Encode renderedText (the displayed QR's source), not the live
                // field, and "--" guards against dash-prefixed text. Mirrors the
                // PNG path's WYSIWYG guarantee.
                Proc.runCommand(
                    "export-qr-svg",
                    ["qrencode", "-t", "SVG", "-s", pluginRoot.qrSize, "-o", destPath, "--", pluginRoot.renderedText],
                    onDone,
                    0
                );
            } else {
                Proc.runCommand(
                    "export-qr",
                    ["sh", "-c", "cp \"$1\" \"$2\"", "sh", activePath, destPath],
                    onDone,
                    0
                );
            }
            close();
        }
        onDialogClosed: isSaving = false
    }

    function copyImageToClipboard() {
        if (!pluginRoot.hasResult) return;
        const activePath = pluginRoot.useImageA ? pluginRoot.pathA : pluginRoot.pathB;
        DMSService.sendRequest("clipboard.copyFile", { "filePath": activePath }, function(response) {
            if (response.error) {
                ToastService.showError("Failed to copy image to clipboard.");
            } else {
                ToastService.showInfo("QR Image copied to clipboard!");
            }
        });
    }

    function copyToClipboard(text) {
        Proc.runCommand(
            "clipboard-copy",
            ["sh", "-c", "echo -n \"" + text + "\" | wl-copy || echo -n \"" + text + "\" | xclip -selection clipboard"],
            (stdout, exitCode) => {
                if (exitCode === 0) {
                    ToastService.showInfo("Text copied to clipboard!");
                }},
            0
        )
    }

    function fetchWifiAndGenerateQR() {
        pluginRoot.isFetchingWifi = true;
        const cmd = "SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2 | head -n 1); " +
                    "if [ -n \"$SSID\" ]; then " +
                    "SEC=$(nmcli -t -f SSID,SECURITY device wifi | grep \"^$SSID:\" | cut -d: -f2 | head -n 1); " +
                    "PWD=$(nmcli -s -g 802-11-wireless-security.psk connection show \"$SSID\"); " +
                    "SEC_TYPE=\"WPA\"; " +
                    "if echo \"$SEC\" | grep -iq \"WEP\"; then SEC_TYPE=\"WEP\"; fi; " +
                    "if [ -z \"$SEC\" ] || [ \"$SEC\" = \"--\" ]; then SEC_TYPE=\"nopass\"; fi; " +
                    "if [ -z \"$PWD\" ]; then SEC_TYPE=\"nopass\"; fi; " +
                    "echo \"WIFI:S:$SSID;T:$SEC_TYPE;P:$PWD;;\"; " +
                    "else echo \"NO_WIFI\"; fi";

        Proc.runCommand(
            "fetch-wifi",
            ["sh", "-c", cmd],
            (stdout, exitCode) => {
                pluginRoot.isFetchingWifi = false;
                const result = stdout.trim();
                if (exitCode === 0 && result !== "NO_WIFI") {
                    pluginRoot.generateText(result);
                }
            },
            0
        )
    }

    function scanFromScreenshot() {
        pluginRoot.isDecoding = true;
        const tempPath = "/tmp/dms-qr-screenshot.png";
        
        Proc.runCommand(
            "screenshot-qr",
            ["dms", "screenshot", "region", "--no-confirm", "--no-notify", "--dir", "/tmp", "--filename", "dms-qr-screenshot.png"],
            (stdout, exitCode) => {
                pluginRoot.isDecoding = false;
                if (exitCode === 0) {
                    pluginRoot.decodeQR(tempPath);
                    pluginRoot.triggerPopout();
                } else {
                    ToastService.showError("Failed to take screenshot or selection cancelled.");
                }
            },
            0
        );
    }


    pillRightClickAction: () => {
        // Fetch clipboard and generate QR before opening popout
        Proc.runCommand(
            "right-click-paste",
            ["sh", "-c", "wl-paste --no-newline || xclip -selection clipboard -o"],
            (stdout, exitCode) => {
                if (exitCode === 0 && stdout !== "") {
                    // Basic validation to avoid binary data (like image data)
                    const isBinary = stdout.includes("\0") || 
                                   stdout.startsWith("\x89PNG") || 
                                   stdout.startsWith("\xff\xd8") ||
                                   stdout.startsWith("GIF8");
                    
                    if (isBinary) {
                        ToastService.showWarning("Clipboard contains binary data, not text.");
                        return;
                    }

                    pluginRoot.generateText(stdout);
                }
                
                // Only trigger (toggle) if not already visible
                if (!pluginRoot.activePopoutReference || !pluginRoot.activePopoutReference.shouldBeVisible) {
                    pluginRoot.triggerPopout();
                }
            },
            0
        )
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: horizontalRow.implicitWidth
            implicitHeight: 24
            anchors.verticalCenter: parent.verticalCenter

            property bool draggingOver: false

            Row {
                id: horizontalRow
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                scale: draggingOver ? 1.2 : 1.0
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                DankIcon {
                    name: "qr_code_2"
                    size: Theme.iconSizeSmall
                    color: draggingOver ? Theme.primary : (pluginRoot.hasResult || pluginRoot.isDecoding ? Theme.primary : Theme.surfaceText)
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "QR"
                    font.pixelSize: Theme.fontSizeSmall
                    color: (pluginRoot.hasResult || pluginRoot.isDecoding) ? Theme.primary : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: pluginRoot.pillStyle === "text"
                }
            }

            DropArea {
                anchors.fill: parent
                onEntered: draggingOver = true
                onExited: draggingOver = false
                onDropped: (drop) => {
                    draggingOver = false;
                    let urls = [];
                    if (drop.hasUrls) {
                        urls = drop.urls.map(url => url.toString());
                    } else if (drop.hasText) {
                        urls = [drop.text];
                    }

                    if (urls.length > 0) {
                        const firstUrl = urls[0];
                        // Check if it's an image file
                        const isImage = firstUrl.toLowerCase().match(/\.(png|jpg|jpeg|webp|bmp)$/);
                        if (isImage) {
                            pluginRoot.decodeQR(firstUrl);
                        } else {
                            pluginRoot.generateText(firstUrl);
                        }
                    }
                    pluginRoot.triggerPopout();
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                    if (mouse.button === Qt.MiddleButton) {
                        pluginRoot.scanFromScreenshot();
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: Theme.iconSize
            implicitHeight: verticalCol.implicitHeight

            property bool draggingOver: false

            Column {
                id: verticalCol
                spacing: Theme.spacingXS
                anchors.horizontalCenter: parent.horizontalCenter
                scale: draggingOver ? 1.2 : 1.0
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                DankIcon {
                    name: "qr_code_2"
                    size: Theme.iconSizeSmall
                    color: draggingOver ? Theme.primary : (pluginRoot.hasResult || pluginRoot.isDecoding ? Theme.primary : Theme.surfaceText)
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: "QR"
                    font.pixelSize: Theme.fontSizeSmall
                    color: (pluginRoot.hasResult || pluginRoot.isDecoding) ? Theme.primary : Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: pluginRoot.pillStyle === "text"
                }
            }

            DropArea {
                anchors.fill: parent
                onEntered: draggingOver = true
                onExited: draggingOver = false
                onDropped: (drop) => {
                    draggingOver = false;
                    let urls = [];
                    if (drop.hasUrls) {
                        urls = drop.urls.map(url => url.toString());
                    } else if (drop.hasText) {
                        urls = [drop.text];
                    }

                    if (urls.length > 0) {
                        const firstUrl = urls[0];
                        const isImage = firstUrl.toLowerCase().match(/\.(png|jpg|jpeg|webp|bmp)$/);
                        if (isImage) {
                            pluginRoot.decodeQR(firstUrl);
                        } else {
                            pluginRoot.generateText(firstUrl);
                        }
                    }
                    pluginRoot.triggerPopout();
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                    if (mouse.button === Qt.MiddleButton) {
                        pluginRoot.scanFromScreenshot();
                    }
                }
            }
        }
    }

    popoutContent: Component {
            PopoutComponent {
                id: mainContent
                width: parent ? parent.width : 0
                headerText: ""
                detailsText: ""
                showCloseButton: false
                focus: true

                property var parentPopout: null
                onParentPopoutChanged: pluginRoot.activePopoutReference = parentPopout

                // The single resolver: decides which input owns the one QR.
                // A filled template (key field set) outranks the free-text field;
                // the active source is released when its key content is cleared,
                // then falls back to another filled input (templates first).
                function resolveQR() {
                    const cFilled = cName.text.trim() !== "";
                    // An event needs at least a title and a start date to be a
                    // valid VEVENT, so it only owns the QR once both are present.
                    const eFilled = evTitle.text.trim() !== "" && evStartDate.text.trim() !== "";
                    const tFilled = pluginRoot.currentText.trim() !== "";

                    let src = pluginRoot.activeSource;
                    if ((src === "contact" && !cFilled) || (src === "event" && !eFilled) || (src === "text" && !tFilled))
                        src = "";
                    if (src === "") {
                        if (cFilled) src = "contact";
                        else if (eFilled) src = "event";
                        else if (tFilled) src = "text";
                    }
                    pluginRoot.activeSource = src;

                    if (src === "contact")
                        pluginRoot.generate(pluginRoot.buildVCard(cName.text, cPhone.text, cEmail.text, cOrg.text, cUrl.text));
                    else if (src === "event")
                        pluginRoot.generate(pluginRoot.buildEvent(evTitle.text, evLoc.text, evStartDate.text, evStartTime.text, evEndDate.text, evEndTime.text));
                    else if (src === "text")
                        pluginRoot.generate(pluginRoot.currentText);
                    else
                        pluginRoot.clearResult();
                }

                PluginShortcut {
                    parentPopout: mainContent.parentPopout
                    onOpened: () => {
                        if (pluginRoot.manualInputInput) {
                            pluginRoot.manualInputInput.forceActiveFocus();
                        }
                    }
                    onEnterPressed: () => {
                        if (pluginRoot.hasResult) {
                            pluginRoot.copyImageToClipboard();
                        }
                    }
                }

                Component.onDestruction: {
                    if (!pluginRoot.isSaving && pluginRoot.clearQrOnClose) {
                        pluginRoot.clearQR();
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingL
                    focus: true

                    // 1. Input & Primary Generation Section
                    Column {
                        width: parent.width
                        spacing: Theme.spacingM

                        DankButton {
                            id: wifiButton
                            text: pluginRoot.isFetchingWifi ? I18n.tr("Fetching Wi-Fi...") : I18n.tr("Share Current Wi-Fi")
                            width: parent.width
                            iconName: pluginRoot.isFetchingWifi ? "sync" : "wifi"
                            backgroundColor: Theme.secondary
                            enabled: !pluginRoot.isFetchingWifi
                            onClicked: pluginRoot.fetchWifiAndGenerateQR()
                        }

                        DankTextField {
                            id: manualInput
                            width: parent.width
                            placeholderText: "Type or paste text here..."
                            showClearButton: true
                            focus: true
                            text: pluginRoot.currentText
                            Component.onCompleted: {
                                pluginRoot.manualInputInput = manualInput;
                            }
                            // Take over the QR only when no template owns it, so
                            // typing here can't overwrite a filled contact/event.
                            onTextEdited: {
                                pluginRoot.currentText = text;
                                if (cName.text.trim() === "" && evTitle.text.trim() === "")
                                    pluginRoot.activeSource = "text";
                                mainContent.resolveQR();
                            }
                            onEditingFinished: mainContent.resolveQR()
                        }
                    }

                    // 1b. Structured Templates (Contact / Calendar Event)
                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        // ---- Contact (vCard) ----
                        Column {
                            id: contactSection
                            width: parent.width
                            spacing: Theme.spacingS
                            property bool expanded: false

                            Rectangle {
                                width: parent.width
                                height: 40
                                radius: Theme.cornerRadius
                                color: "transparent"

                                DankIcon {
                                    id: contactHdrIcon
                                    name: "contact_phone"
                                    size: Theme.iconSizeSmall
                                    color: Theme.surfaceText
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: I18n.tr("Contact (vCard)")
                                    font.weight: Font.Medium
                                    anchors.left: contactHdrIcon.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                DankIcon {
                                    name: "expand_more"
                                    size: Theme.iconSizeSmall
                                    color: Theme.surfaceText
                                    rotation: contactSection.expanded ? 180 : 0
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    Behavior on rotation { NumberAnimation { duration: 150 } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: contactSection.expanded = !contactSection.expanded
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingS
                                clip: true
                                height: contactSection.expanded ? implicitHeight : 0
                                visible: height > 0
                                Behavior on height { NumberAnimation { duration: 150 } }

                                DankTextField { id: cName;  width: parent.width; placeholderText: "Full name";     onTextEdited: { pluginRoot.activeSource = "contact"; mainContent.resolveQR(); } }
                                DankTextField { id: cPhone; width: parent.width; placeholderText: "Phone";         onTextEdited: { pluginRoot.activeSource = "contact"; mainContent.resolveQR(); } }
                                DankTextField { id: cEmail; width: parent.width; placeholderText: "Email";         onTextEdited: { pluginRoot.activeSource = "contact"; mainContent.resolveQR(); } }
                                DankTextField { id: cOrg;   width: parent.width; placeholderText: "Organization";  onTextEdited: { pluginRoot.activeSource = "contact"; mainContent.resolveQR(); } }
                                DankTextField { id: cUrl;   width: parent.width; placeholderText: "Website / URL"; onTextEdited: { pluginRoot.activeSource = "contact"; mainContent.resolveQR(); } }
                            }
                        }

                        // ---- Calendar Event ----
                        Column {
                            id: eventSection
                            width: parent.width
                            spacing: Theme.spacingS
                            property bool expanded: false

                            Rectangle {
                                width: parent.width
                                height: 40
                                radius: Theme.cornerRadius
                                color: "transparent"

                                DankIcon {
                                    id: eventHdrIcon
                                    name: "event"
                                    size: Theme.iconSizeSmall
                                    color: Theme.surfaceText
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: I18n.tr("Calendar Event")
                                    font.weight: Font.Medium
                                    anchors.left: eventHdrIcon.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                DankIcon {
                                    name: "expand_more"
                                    size: Theme.iconSizeSmall
                                    color: Theme.surfaceText
                                    rotation: eventSection.expanded ? 180 : 0
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    Behavior on rotation { NumberAnimation { duration: 150 } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: eventSection.expanded = !eventSection.expanded
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingS
                                clip: true
                                height: eventSection.expanded ? implicitHeight : 0
                                visible: height > 0
                                Behavior on height { NumberAnimation { duration: 150 } }

                                DankTextField { id: evTitle; width: parent.width; placeholderText: "Event title"; onTextEdited: { pluginRoot.activeSource = "event"; mainContent.resolveQR(); } }
                                DankTextField { id: evLoc;   width: parent.width; placeholderText: "Location";    onTextEdited: { pluginRoot.activeSource = "event"; mainContent.resolveQR(); } }

                                StyledText {
                                    text: I18n.tr("Start")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceTextSecondary
                                }
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS
                                    DankTextField { id: evStartDate; width: (parent.width - Theme.spacingS) * 0.58; placeholderText: "YYYY-MM-DD"; onTextEdited: { pluginRoot.activeSource = "event"; mainContent.resolveQR(); } }
                                    DankTextField { id: evStartTime; width: (parent.width - Theme.spacingS) * 0.42; placeholderText: "HH:MM"; onTextEdited: { pluginRoot.activeSource = "event"; mainContent.resolveQR(); } }
                                }
                                StyledText {
                                    text: I18n.tr("End")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceTextSecondary
                                }
                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS
                                    DankTextField { id: evEndDate; width: (parent.width - Theme.spacingS) * 0.58; placeholderText: "YYYY-MM-DD"; onTextEdited: { pluginRoot.activeSource = "event"; mainContent.resolveQR(); } }
                                    DankTextField { id: evEndTime; width: (parent.width - Theme.spacingS) * 0.42; placeholderText: "HH:MM"; onTextEdited: { pluginRoot.activeSource = "event"; mainContent.resolveQR(); } }
                                }
                            }
                        }
                    }

                    // 2. QR Display Area (The Result)
                    StyledRect {
                        width: parent.width
                        height: width
                        color: "white"
                        radius: Theme.cornerRadius
                        border.width: 1
                        border.color: Theme.surfaceContainerHighest
                        
                        Image {
                            id: qrImageA
                            anchors.fill: parent
                            anchors.margins: 16
                            source: pluginRoot.sourceA
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            opacity: pluginRoot.useImageA ? 1 : 0
                            visible: opacity > 0 && !pluginRoot.isFetchingWifi
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                            onStatusChanged: {
                                if (status === Image.Ready && !pluginRoot.useImageA) {
                                    pluginRoot.useImageA = true;
                                }
                            }
                        }

                        Image {
                            id: qrImageB
                            anchors.fill: parent
                            anchors.margins: 16
                            source: pluginRoot.sourceB
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            opacity: !pluginRoot.useImageA ? 1 : 0
                            visible: opacity > 0 && !pluginRoot.isFetchingWifi
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                            onStatusChanged: {
                                if (status === Image.Ready && pluginRoot.useImageA) {
                                    pluginRoot.useImageA = false;
                                }
                            }
                        }

                        // Unified Status Overlay
                        DankIcon {
                            anchors.centerIn: parent
                            name: "sync"
                            size: 48
                            color: Theme.primary
                            visible: pluginRoot.isFetchingWifi || pluginRoot.isDecoding
                            
                            RotationAnimation on rotation {
                                running: pluginRoot.isFetchingWifi || pluginRoot.isDecoding
                                from: 0; to: 360; duration: 1000
                                loops: Animation.Infinite
                            }
                        }
                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.spacingS
                            visible: pluginRoot.sourceA === "" && pluginRoot.sourceB === "" && !pluginRoot.isFetchingWifi
                            opacity: 0.5
                            DankIcon {
                                anchors.horizontalCenter: parent.horizontalCenter
                                name: "qr_code_2"
                                size: 48
                                color: Theme.onSurfaceVariant
                            }
                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: I18n.tr("Ready to generate")
                                color: Theme.onSurfaceVariant
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }
                    }

                    // 3. Post-Generation Actions
                    Column {
                        width: parent.width
                        spacing: Theme.spacingM
                        visible: pluginRoot.hasResult

                        DankButton {
                            text: I18n.tr("Copy Image")
                            width: parent.width
                            iconName: "content_copy"
                            backgroundColor: Theme.primary
                            enabled: pluginRoot.hasResult
                            onClicked: pluginRoot.copyImageToClipboard()
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            DankButton {
                                text: I18n.tr("Save PNG")
                                width: (parent.width - Theme.spacingS) / 2
                                iconName: "save"
                                backgroundColor: Theme.surfaceContainerHighest
                                textColor: Theme.surfaceText
                                enabled: pluginRoot.hasResult
                                onClicked: pluginRoot.saveImage("png")
                            }

                            DankButton {
                                text: I18n.tr("Save SVG")
                                width: (parent.width - Theme.spacingS) / 2
                                iconName: "shape_line"
                                backgroundColor: Theme.surfaceContainerHighest
                                textColor: Theme.surfaceText
                                enabled: pluginRoot.hasResult
                                onClicked: pluginRoot.saveImage("svg")
                            }
                        }
                    }
                    
                    HintSection {
                        width: parent.width - Theme.spacingL * 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        showHints: pluginRoot.showHints

                        HintItem {
                            icon: "lightbulb"
                            text: I18n.tr("Tip: Drop a link or image on the pill icon to generate/decode QR")
                        }
                        HintItem {
                            icon: "info"
                            text: I18n.tr("Right-click icon pill to paste, Middle-click to scan screenshot")
                        }
                    }
                }
            }
        }

    popoutWidth: 350
    popoutHeight: {
        let h = (pluginRoot.hasResult) ? 560 : 424;
        return pluginRoot.showHints ? h : h - 40;
    }
}

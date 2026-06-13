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
    
    property string currentText: ""
    // Exact string encoded by the currently displayed QR (set once generation
    // succeeds). SVG export uses this so it stays WYSIWYG like the PNG path,
    // even if currentText has already advanced during a debounce/render cycle.
    property string renderedText: ""
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
        id: debounceTimer
        interval: 200
        repeat: false
        onTriggered: pluginRoot.generateQRInternal(pluginRoot.currentText)
    }

    function clearQR() {
        currentText = "";
        renderedText = "";
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
                    pluginRoot.generateQR(stdout.trim());
                } else {
                    pluginRoot.droppedImagePath = "";
                    ToastService.showError("Failed to decode QR code.");
                }
            },
            0
        );
    }

    function generateQR(text) {
        if (!text || text.trim() === "") {
            currentText = "";
            sourceA = "";
            sourceB = "";
            hasResult = false;
            return;
        }
        currentText = text;
        debounceTimer.restart();
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
                    pluginRoot.currentText = result;
                    if (pluginRoot.manualInputInput) pluginRoot.manualInputInput.text = result;
                    pluginRoot.generateQR(result);
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

                    pluginRoot.currentText = stdout;
                    pluginRoot.generateQR(stdout);
                    if (pluginRoot.manualInputInput) pluginRoot.manualInputInput.text = stdout;
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
                            pluginRoot.generateQR(firstUrl);
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
                            pluginRoot.generateQR(firstUrl);
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
                            onTextEdited: pluginRoot.generateQR(text)
                            onEditingFinished: pluginRoot.generateQR(text)
                            onTextChanged: {
                                if (text === "") {
                                    debounceTimer.stop();
                                    pluginRoot.currentText = "";
                                    pluginRoot.hasResult = false;
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

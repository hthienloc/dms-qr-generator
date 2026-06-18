import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "./dms-common"

PluginSettings {
    id: root
    pluginId: "qrGenerator"

    SettingsCard {
        id: generalSection
        SectionTitle { 
            text: I18n.tr("Generation & Privacy")
            icon: "security"
            showReset: clearQrOnClose.isDirty || qrSize.isDirty || errorCorrection.isDirty
            onResetClicked: {
                clearQrOnClose.resetToDefault();
                qrSize.resetToDefault();
                errorCorrection.resetToDefault();
            }
        }

        ToggleSettingPlus {
            id: clearQrOnClose
            settingKey: "clearQrOnClose"
            label: I18n.tr("Clear QR Code on Close")
            description: I18n.tr("Automatically clear the text and QR code when you close the popout for privacy.")
            defaultValue: true
        }

        Separator {}

        SelectionSettingPlus {
            id: qrSize
            settingKey: "qrSize"
            label: I18n.tr("QR Code Size")
            options: [
                { label: I18n.tr("Small"), value: "3" },
                { label: I18n.tr("Medium"), value: "6" },
                { label: I18n.tr("Large"), value: "10" }
            ]
            defaultValue: "6"
        }

        Separator {}

        SelectionSettingPlus {
            id: errorCorrection
            settingKey: "errorCorrection"
            label: I18n.tr("Error Correction Level")
            description: I18n.tr("Higher levels keep the code scannable even when partly damaged or covered, at the cost of a denser code.")
            options: [
                { label: I18n.tr("Low (L)"), value: "L" },
                { label: I18n.tr("Medium (M)"), value: "M" },
                { label: I18n.tr("Quartile (Q)"), value: "Q" },
                { label: I18n.tr("High (H)"), value: "H" }
            ]
            defaultValue: "M"
        }
    }

    SettingsCard {
        id: displaySection
        SectionTitle { 
            text: I18n.tr("Display & UI")
            icon: "desktop_windows"
            showReset: pillStyle.isDirty
            onResetClicked: {
                pillStyle.resetToDefault();
            }
        }

        SelectionSettingPlus {
            id: pillStyle
            settingKey: "pillStyle"
            label: I18n.tr("Bar Display Style")
            options: [
                { label: I18n.tr("Icon Only"), value: "icon" },
                { label: I18n.tr("Icon + Text"), value: "text" }
            ]
            defaultValue: "icon"
        }
    }

    SettingsCard {
        SectionTitle { text: I18n.tr("Installation"); icon: "download" }

        InfoText {
            text: I18n.tr("Install the required package:")
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Repeater {
                model: [
                    { cmd: "sudo dnf install qrencode", label: "Fedora" },
                    { cmd: "sudo pacman -S qrencode", label: "Arch Linux" },
                    { cmd: "sudo apt install qrencode", label: "Debian/Ubuntu" },
                    { cmd: "sudo zypper install qrencode", label: "openSUSE" }
                ]

                delegate: CopyBox {
                    label: modelData.label
                    text: modelData.cmd
                }
            }
        }
    }

    SettingsCard {
        id: behaviorSection
        SectionTitle { 
            text: I18n.tr("Behavior")
            icon: "settings"
            showReset: showHints.isDirty
            onResetClicked: {
                showHints.resetToDefault();
            }
        }

        ToggleSettingPlus {
            id: showHints
            settingKey: "showHints"
            label: I18n.tr("Show Hints")
            defaultValue: true
        }
    }

    SettingsCard {
        SectionTitle { 
            id: usageTitle
            text: I18n.tr("Usage Guide")
            icon: "menu_book" 
            collapsible: true
            settingKey: "usageGuideExpanded"
        }

        UsageGuide {
            expanded: usageTitle.isExpanded
            items: [
                I18n.tr("<b>Left-click</b> the pill to open the generator."),
                I18n.tr("<b>Right-click</b> the pill to generate from clipboard."),
                I18n.tr("<b>Middle-click</b> the pill to screenshot and scan region."),
                I18n.tr("<b>Drop image</b> onto the pill or popout to scan QR code."),
                I18n.tr("<b>Drop text</b> onto the pill or popout to generate QR code."),
                I18n.tr("Click the <b>WiFi icon</b> to quickly share current network.")
            ]
        }
    }

    PluginAbout {
        repoUrl: "https://github.com/hthienloc/dms-qr-generator"
    }
}

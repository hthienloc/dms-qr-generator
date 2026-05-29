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
        SectionTitle { text: I18n.tr("Generation & Privacy"); icon: "security" }

        ToggleSetting {
            settingKey: "clearQrOnClose"
            label: I18n.tr("Clear QR Code on Close")
            description: I18n.tr("Automatically clear the text and QR code when you close the popout for privacy.")
            defaultValue: true
        }

        SelectionSetting {
            settingKey: "qrSize"
            label: I18n.tr("QR Code Size")
            description: I18n.tr("The resolution/scale of the generated QR code.")
            options: [
                { label: I18n.tr("Small"), value: "3" },
                { label: I18n.tr("Medium"), value: "6" },
                { label: I18n.tr("Large"), value: "10" }
            ]
            defaultValue: "6"
        }
    }

    SettingsCard {
        SectionTitle { text: I18n.tr("Display & UI"); icon: "desktop_windows" }

        SelectionSetting {
            settingKey: "pillStyle"
            label: I18n.tr("Bar Display Style")
            description: I18n.tr("Choose how the plugin is displayed on the bar.")
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
        SectionTitle { text: I18n.tr("Behavior"); icon: "settings" }

        ToggleSetting {
            settingKey: "showHints"
            label: I18n.tr("Show Hints")
            description: I18n.tr("Display helpful usage tips and shortcuts at the bottom of the popout.")
            defaultValue: true
        }
    }

    PluginAbout {
        repoUrl: "https://github.com/hthienloc/dms-qr-generator"
    }
}

/*
    SPDX-FileCopyrightText: 2014 Marco Martin <mart@kde.org>
    SPDX-FileCopyrightText: 2026 AstroOS <https://github.com/bakathefish/ASTRO-OS>

    SPDX-License-Identifier: GPL-2.0-or-later
*/

// Adapted from plasma-workspace lookandfeel/org.kde.breeze/contents/splash/
// Splash.qml: the same stage property, the same fade-in of the content item
// when stage reaches 2, and the same Kirigami units so the splash scales the
// way every other Plasma surface does.
//
// What changed: the flat black ground is the AstroOS space gradient, the same
// two stops the wallpaper and the boot splash use, so the handover from
// Plymouth to ksplash to the desktop is one continuous surface. The logo is a
// third of Breeze's size because this screen should not announce anything.
// Breeze's spinning busy image and its "Plasma made by KDE" row are gone; a
// progress line replaces them, which says the same thing without a font.

import QtQuick
import org.kde.kirigami as Kirigami

Rectangle {
    id: root

    // space_top to space_bottom, the gradient from astroos/branding/palette.py
    gradient: Gradient {
        GradientStop { position: 0.0; color: "#03020a" }
        GradientStop { position: 1.0; color: "#0e0820" }
    }

    // ksplash sets this as each startup phase reports in: 1 before anything
    // has started, 6 when the desktop is up
    property int stage

    onStageChanged: {
        if (stage == 2) {
            introAnimation.running = true;
        }
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: 0

        Image {
            id: logo
            // about 90 px on a 1080p screen, where gridUnit is about 18 px
            readonly property real size: Kirigami.Units.gridUnit * 5

            anchors.centerIn: parent

            asynchronous: true
            // astroos-branding owns this path and is a hard dependency
            source: "file:///usr/share/icons/hicolor/scalable/apps/astroos-logo.svg"

            // an SVG rasterises at sourceSize, so it must be set to be sharp
            sourceSize.width: size
            sourceSize.height: size
        }

        Rectangle {
            id: progressTrack
            width: Kirigami.Units.gridUnit * 12
            height: 2
            color: "#332b4f"

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: logo.bottom
            anchors.topMargin: Kirigami.Units.gridUnit * 2

            Rectangle {
                id: progressFill
                height: parent.height
                color: "#8658b4"

                anchors.left: parent.left
                // stage 1 is nothing done, stage 6 is the desktop, so five
                // steps of the line; clamped because the stage count is
                // ksplash's to change, not ours
                width: parent.width * Math.max(0, Math.min(1, (root.stage - 1) / 5))

                Behavior on width {
                    NumberAnimation {
                        duration: Kirigami.Units.longDuration
                        easing.type: Easing.InOutQuad
                    }
                }
            }
        }
    }

    OpacityAnimator {
        id: introAnimation
        running: false
        target: content
        from: 0
        to: 1
        duration: Kirigami.Units.veryLongDuration * 2
        easing.type: Easing.InOutQuad
    }
}

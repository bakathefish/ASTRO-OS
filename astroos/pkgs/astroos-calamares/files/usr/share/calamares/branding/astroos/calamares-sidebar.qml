/* Horizontal (bottom) progress bar for the AstroOS branding component.

   SPDX-FileCopyrightText: 2020 Adriaan de Groot <groot@kde.org>
   SPDX-FileCopyrightText: 2021 Anke Boersma <demm@kaosx.us>
   SPDX-License-Identifier: GPL-3.0-or-later

   Verbatim from the CachyOS branding component (itself the Calamares sample):
   every colour and the logo come from Branding, so only branding.desc changes.
*/

import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.3
import QtQuick.Layouts 1.3
import QtQuick.Controls 2.15

Rectangle {
    id: sideBar;
    color: Branding.styleString( Branding.SidebarBackground );
    height: 38;
    width: parent.width;

    RowLayout {
        anchors.fill: parent;
        spacing: 2;

        Image {
            Layout.leftMargin: 12;
            Layout.rightMargin: 12;
            Layout.alignment: Qt.AlignCenter;
            id: logo;
            width: 30;
            height: width;  // square
            source: "file:/" + Branding.imagePath(Branding.ProductLogo);
            sourceSize.width: width;
            sourceSize.height: height;
        }

        Repeater {
            model: ViewManager
            Rectangle {
                Layout.leftMargin: 6;
                Layout.rightMargin: 6;
                Layout.fillWidth: true;
                Layout.alignment: Qt.AlignCenter;
                height: 32;
                radius: 6;
                color: Branding.styleString( index == ViewManager.currentStepIndex ? Branding.SidebarBackgroundCurrent : Branding.SidebarBackground );

                Text {
                    horizontalAlignment: Text.AlignHCenter;
                    verticalAlignment: Text.AlignVCenter;
                    anchors.verticalCenter: parent.verticalCenter;
                    anchors.horizontalCenter: parent.horizontalCenter;
                    x: parent.x + 12;
                    color: Branding.styleString( index == ViewManager.currentStepIndex ? Branding.SidebarTextCurrent : Branding.SidebarText );

                    text: display;
                    width: parent.width;
                    wrapMode: Text.WordWrap;
                    font.weight: (index == ViewManager.currentStepIndex ? Font.Bold : Font.Normal);
                    font.pointSize : (index == ViewManager.currentStepIndex ? 10 : 9);
                }
            }
        }

        Item {
            Layout.fillHeight: true;
        }
    }
}

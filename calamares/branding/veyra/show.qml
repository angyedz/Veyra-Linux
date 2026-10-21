import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Timer {
        interval: 5000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#111827" }
                GradientStop { position: 1.0; color: "#312e81" }
            }
        }
        Column {
            anchors.centerIn: parent
            spacing: 14
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Veyra Linux"
                color: "#ffffff"
                font.pixelSize: 38
                font.bold: true
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "A simple way to get started with Linux"
                color: "#dbeafe"
                font.pixelSize: 19
            }
        }
    }

    Slide {
        centeredText: qsTr("Your computer is being prepared for KDE Plasma.")
    }

    Slide {
        centeredText: qsTr("Keep your computer connected to power while installation finishes.")
    }

    function onActivate() {
        presentation.currentSlide = 0
    }

    function onLeave() {
    }
}

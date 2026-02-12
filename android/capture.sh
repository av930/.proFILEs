#!/bin/bash
#need to run "adb root"
IMG_PROG=/cygdrive/d/.gradle/OneDrive/_MyProgram/_MultiMedia/IrfanView/i_view32.exe
IMG_IN=screen.png
IMG_OUT=screen-$(date +%s).png
rm -f *.png


if false; then
    echo use convert
    #adb shell screencap -p | sed 's/\r$//' > $IMG_IN
    #convert -resize 480X854 -quality 100 -sharpen 0x1.0 $IMG_IN $IMG_OUT
    adb -d shell screencap /sdcard/$IMG_IN; 
    adb pull /sdcard/$IMG_IN
    convert -resize 480X854 -quality 100 -sharpen 0x1.0 $IMG_IN $IMG_OUT

else
    adb -d devices
    echo use irfranviewer
    #adb shell screencap -p | sed 's/\r$//' > $IMG_IN
    adb -d shell screencap /sdcard/$IMG_IN > /dev/null
    adb -d pull /sdcard/$IMG_IN > /dev/null
    $IMG_PROG $IMG_IN /resize=\(480,854\) /resample /aspectratio /clipcopy /convert=$IMG_OUT > /dev/null
fi

$IMG_PROG $IMG_OUT&


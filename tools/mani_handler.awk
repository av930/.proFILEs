#! /usr/bin/awk -f
#### Pre Process
BEGIN {
    DEBUG="true"
    FS="\t"; OFS="\t"
    #FPAT="([^ ]+=\"[^\"]+\")" #field형식 정의
    SofColumn=0; LofColumn=SofColumn+7
}


#### Main Process
## hemote section
/$1 ~ git-check-url/ {
         git ls-remote ssh://lamp.lge.com:29418/platform/art |grep $7
    }
}


#### Post Process
END {

}
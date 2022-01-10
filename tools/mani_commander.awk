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
/<remote/ {
    print "<< remote info >>"
    for(i=1; i<=NF; i++) {
        if (match($i, "name="))          {remote[SofColumn+01]=$i}
        if (match($i, "fetch="))         {remote[SofColumn+02]=$i}
        if (match($i, "revision="))      {remote[SofColumn+03]=$i}
        if (match($i, "pushurl="))       {remote[SofColumn+04]=$i}
    }
    j=1; while(j<=LofColumn) {printf "%s%s", remote[j++], OFS}
    printf "\n"
    #remote[LofColumn]="\n"    
}


## default section
/<default/ {
    print "<< default info >>"
    for(i=1; i<=NF; i++) {
        if (match($i, "remote="))        {defaults[SofColumn+01]=$i}
        if (match($i, "dest-branch="))   {defaults[SofColumn+02]=$i}
        if (match($i, "revision="))      {defaults[SofColumn+03]=$i}
        if (match($i, "upstream="))      {defaults[SofColumn+04]=$i}
    }
    j=1; while(j<=LofColumn) {printf "%s%s", defaults[j++], OFS}
    print "@@@@ Manifest Handling @@@@\n " 
    print "\nCOMMAND" OFS "TARGET" OFS "RESULT" OFS "NAME" OFS "PATH" OFS "REVISION" OFS "UPSTREAM"     
    #defaults[LofColumn]="\n"    
    
}


## project section
#name=""; path=""; groups=""; revision=""; upstream=""; destbranch=""
/<project/ {
    NofProj++
    for(i=1; i<=NF; i++) {

        if (match($i, "name="))            {sub(/name=/,"",$i);     project[SofColumn+04]=$i}        
        if (match($i, "path="))            {sub(/path=/,"",$i);     project[SofColumn+05]=$i}        
        if (match($i, "revision="))        {sub(/revision=/,"",$i); project[SofColumn+06]=$i}        
        if (match($i, "upstream="))        {sub(/upstream=/,"",$i); project[SofColumn+07]=$i}        
    }
    j=1; while(j<=LofColumn) {printf "%s%s", project[j++], OFS}
    printf "\n"    
    #project[LofColumn]="\n"
}


#### Post Process
END {
    if ( DEBUG == "true" ) {printf "#ofProjects=[%s] %s #ofLines=[%s]", NofProj, OFS, FNR}
}
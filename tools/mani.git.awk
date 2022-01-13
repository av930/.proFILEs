#! /usr/bin/awk -f
#### Pre Process
BEGIN {
    DEBUG="true"
    FS="\t"; OFS="\t"
    #FPAT="([^ ]+=\"[^\"]+\")"          #field형식 정의
    SofColumn=3; LofColumn=SofColumn+7; #skip 3 column, 4 data exist 
    Command=1                           #command field is from col 1st ~ 3rd
    #array init by space
    print "FORALL" OFS "noop"
    print "COMMAND" OFS "TARGET" OFS "RESULT" OFS "NAME" OFS "PATH" OFS "REVISION" OFS "UPSTREAM"
}


## project section
#name=""; path=""; groups=""; revision=""; upstream=""; destbranch=""
/<project/ {
    NofProj++
    for (i=0; i<=LofColumn+1; i++) {project[i]=" "}        
    for(i=1; i<=NF; i++) {
        if (match($i, "name="))            {sub(/name=/,"",$i);     project[SofColumn+01]=$i}
        if (match($i, "path="))            {sub(/path=/,"",$i);     project[SofColumn+02]=$i}        
        if (match($i, "revision="))        {sub(/revision=/,"",$i); project[SofColumn+03]=$i}        
        if (match($i, "upstream="))        {sub(/upstream=/,"",$i); project[SofColumn+04]=$i}        
    }
    j=1; while(j<=LofColumn) {printf "%s%s", project[j++], OFS}
    printf "\n"    
    #project[LofColumn]="\n"
}


#### Post Process
END {
    #if ( DEBUG == "true" ) {printf "#ofProjects=[%s] %s #ofLines=[%s]", NofProj, OFS, FNR}
}
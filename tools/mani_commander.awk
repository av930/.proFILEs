#! /usr/bin/awk -f
#### Pre Process
BEGIN {
    DEBUG="true"
    FS="\t"; OFS="\t"
    #FPAT="([^ ]+=\"[^\"]+\")"          #field형식 정의
    SofColumn=3; LofColumn=SofColumn+7; #skip 3 column 
    Command=1                           #command field is from col 1st ~ 3rd
    #array init by space
}


#### Main Process
## remote section
/<remote/ {
    for (i=0; i<=LofColumn+1; i++) {remote[i]=" "}
    for(i=1; i<=NF; i++) {
        if (match($i, "name="))         {sub(/name=/,"",$i);       remote[SofColumn+01]=$i}
        if (match($i, "fetch="))        {sub(/fetch=/,"",$i);      remote[SofColumn+02]=$i}
        if (match($i, "revision="))     {sub(/revision=/,"",$i);   remote[SofColumn+03]=$i}
        if (match($i, "pushurl="))      {sub(/pushurl=/,"",$i);    remote[SofColumn+04]=$i}
        remote[Command]="register-remote" 
    }
    j=1; while(j<=LofColumn) {printf "%s%s", remote[j++], OFS} 
    printf "\n"
    #remote[LofColumn]="\n"    
}


## default section
/<default/ {
    for (i=0; i<=LofColumn+1; i++) {defaults[i]=" "}
    for(i=1; i<=NF; i++) {
        if (match($i, "remote="))       {sub(/remote=/,"",$i);      defaults[SofColumn+01]=$i}
        if (match($i, "dest-branch="))  {sub(/dest-branch=/,"",$i); defaults[SofColumn+02]=$i}
        if (match($i, "revision="))     {sub(/revision=/,"",$i);    defaults[SofColumn+03]=$i}
        if (match($i, "upstream="))     {sub(/upstream=/,"",$i);    defaults[SofColumn+04]=$i}
        defaults[Command]="select-default"
    }
    j=1; while(j<=LofColumn) {printf "%s%s", defaults[j++], OFS}
    printf "\n"    
    print "COMMAND" OFS "TARGET" OFS "RESULT" OFS "NAME" OFS "PATH" OFS "REVISION" OFS "UPSTREAM" "\n"     
    #defaults[LofColumn]="\n"
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
    if ( DEBUG == "true" ) {printf "#ofProjects=[%s] %s #ofLines=[%s]", NofProj, OFS, FNR}
}
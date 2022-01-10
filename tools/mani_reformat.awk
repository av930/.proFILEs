#! /usr/bin/awk -f
#### Pre Process
BEGIN {
    DEBUG="true"
    
    ## excel이 csv파일 로드시 groups="ABC, 123"같이 ,와 ", 공백이 섞인것을 제대로 parsing못해, 구분자를 ;로 변경함
    ## 따라서 manifest.xml안에는 ;가 포함되어 있지 않아야함. 
    FS=" "; OFS="\t"
    #FPAT="([^ ]+=\"[^\"]+\")" #field형식 정의
    SofColumn=1; LofColumn=13
}

#### Main Process
## hemote section
/<remote/ {
    remote[SofColumn]="<remote"
    for(i=SofColumn; i<=NF; i++) {
        if (match($i, "name="))          {remote[SofColumn+01]=$i}
        if (match($i, "fetch="))         {remote[SofColumn+02]=$i}
        if (match($i, "alias="))         {remote[SofColumn+03]=$i}
        if (match($i, "revision="))      {remote[SofColumn+04]=$i}
        if (match($i, "pushurl="))       {remote[SofColumn+05]=$i}
        if (match($i, "review="))        {remote[SofColumn+06]=$i}
    }
    remote[LofColumn]=$NF"\n"
    j=1; while(j<=LofColumn) {printf "%s%s", OFS, remote[j++]}
}


## default section
/<default/ {
    defaults[SofColumn]="<default"
    for(i=SofColumn; i<=NF; i++) {
        if (match($i, "remote="))        {defaults[SofColumn+01]=$i}
        if (match($i, "sync-j="))        {defaults[SofColumn+02]=$i}
        if (match($i, "sync-c="))        {defaults[SofColumn+03]=$i}
        if (match($i, "revision="))      {defaults[SofColumn+04]=$i}
        if (match($i, "upstream="))      {defaults[SofColumn+05]=$i}
        if (match($i, "dest-branch="))   {defaults[SofColumn+06]=$i}
        if (match($i, "sync-s="))        {defaults[SofColumn+07]=$i}
        if (match($i, "sync-tags="))     {defaults[SofColumn+08]=$i}
    }
    defaults[LofColumn]=$NF"\n"
    j=1; while(j<=LofColumn) {printf "%s%s", OFS, defaults[j++]}
}


## project section
#name=""; path=""; groups=""; revision=""; upstream=""; destbranch=""
/<project/ {
    NofProj++
    project[SofColumn]="<project"
    for(i=SofColumn; i<=NF; i++) {
        if (match($i, "name="))          {project[SofColumn+01]=$i}
        if (match($i, "path="))          {project[SofColumn+02]=$i}
        if (match($i, "groups="))        {project[SofColumn+03]=$i}
        if (match($i, "revision="))      {project[SofColumn+04]=$i}
        if (match($i, "upstream="))      {project[SofColumn+05]=$i}
        if (match($i, "dest-branch="))   {project[SofColumn+06]=$i}
        if (match($i, "sync-c="))        {project[SofColumn+07]=$i}
        if (match($i, "sync-s="))        {project[SofColumn+08]=$i}
        if (match($i, "sync-tags="))     {project[SofColumn+09]=$i}
        if (match($i, "clone-depth="))   {project[SofColumn+10]=$i}
        if (match($i, "force-path="))    {project[SofColumn+11]=$i}
    }
    project[LofColumn]=$NF"\n"
    j=1; while(j<=LofColumn) {printf "%s%s", OFS, project[j++]}
}


/<linkfile/ {
    linkfile[SofColumn]="<linkfile"
    for(i=SofColumn; i<=NF; i++) {
        if (match($i, "src="))           {linkfile[SofColumn+01]=$i}
        if (match($i, "dest="))          {linkfile[SofColumn+02]=$i}
    }
    linkfile[LofColumn]=$NF"\n"
    j=1; while(j<=LofColumn) {printf "%s%s", OFS, linkfile[j++]}
}



/<copyfile/ {
    copyfile[SofColumn]="<copyfile"
    for(i=SofColumn; i<=NF; i++) {
        if (match($i, "src="))           {copyfile[SofColumn+01]=$i}
        if (match($i, "dest="))          {copyfile[SofColumn+02]=$i}
    }
    copyfile[LofColumn]=$NF"\n"
    j=1; while(j<=LofColumn) {printf "%s%s", OFS, copyfile[j++]}
}


## header/tail section
/(manifest>|<\?xml)/ {
    print $1,$2,$3,$4,$5,$6,$7,$8,$9
}

## body section
/(<notice|<remove|<repo-hooks|<include|<extend-project|project>|<!--)/ {
    print OFS $1,$2,$3,$4,$5,$6,$7,$8,$9
}


#### Post Process
END {

}
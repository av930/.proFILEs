#!/bin/bash
cat -nA $1
printf "\n============================================next:\n"


n=0; while read line; do 
    printf "%2d: %s\n" $((n=n+1)) "$line"
done < $1
read -p "========: simple loop"

IFS='';n=0; while read -r line || [[ -n $line ]]; do 
    printf "%2d: %s\n" $((n=n+1)) "$line"
done < $1
read -p "========: IFS, read -r"


IFS='';n=0; cat $1 | while read -r line || [[ -n $line ]]; do
    printf "%2d: %s\n" $((n=n+1)) "$line"
done
read -p "========: same above"


readarray -t my_array < $1
IFS='';n=0; for line in "${my_array[@]}"; do
  printf "%2d: %s\n" $((n=n+1)) "$line"
done
read -p "========: readarray"


IFS=$'\n'; n=0; for line in $(cat $1); do 
    printf "%2d: %s\n" $((n=n+1)) "$line"
done
read -p "========: read after cat"

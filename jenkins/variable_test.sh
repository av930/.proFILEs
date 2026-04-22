#!/bin/bash

# variable.sh 로드
source "$(dirname "$0")/variable.sh"

echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
echo "=== Step 1: Create variable_create.txt with HERE-DOC ==="
cat > variable_create.txt << 'EOF'
AAA=BBB
MMM=BBB #comment
CCC="DDD=EEE"
FFF="YYY ZZZ
AAAA"
KKK="ZZZ=
EEETTT"
EOF

echo "variable_create.txt created:"
cat variable_create.txt
echo ""

mapfile -t VAR_NAMES < <(grep -oP '^[A-Za-z_][A-Za-z0-9_]*(?==)' variable_create.txt)
declare -a VAR_NAMES
echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
echo "=== Step 2: Import variables from variable_create.txt ==="
defineVariable_import variable_create.txt

echo "Variables imported:"
for var in "${VAR_NAMES[@]}"; do
    printf "  %s=%s\n" "$var" "${!var}"
done

echo ""
echo "Declare output (Step 2):"
{
    for var in "${VAR_NAMES[@]}"; do
        declare -p "$var"
    done
} | tee variable_step2.txt
echo ""

echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
echo "=== Step 3: Define ARR array and export ==="
ARR=()
for var in "${VAR_NAMES[@]}"; do
    ARR+=("$var=${!var}")
done
defineVariable_export
echo "Variables exported to: $BUILTIN_BACKUP_FILE"
cat "$BUILTIN_BACKUP_FILE"
echo ""


echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
echo "=== Step 4: Clear variables and re-import ==="
unset "${VAR_NAMES[@]}"
echo "Variables cleared"
echo ""

defineVariable_import
echo "Variables re-imported from default source"

echo ""
echo "Declare output (Step 4):"
{
    for var in "${VAR_NAMES[@]}"; do
        declare -p "$var"
    done
} | tee variable_step4.txt
echo ""


echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
echo "=== Step 5: Print all variables ==="
defineVariable_print
echo ""

echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
echo "=== Step 6: Compare Step 2 and Step 4 declare outputs ==="
if diff -q variable_step2.txt variable_step4.txt > /dev/null 2>&1;
then echo -e "\033[92m\033[1m[OKAY]\033[0m Both imports are identical - declare outputs match!"
else echo -e "\033[91m\033[1m[FAIL]\033[0m Imports differ - declare outputs mismatch"
     echo "Differences:"
     diff variable_step2.txt variable_step4.txt
fi

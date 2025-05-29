#https://github.com/neurobin/shc

sudo add-apt-repository ppa:neurobin/ppa
sudo apt-get update
sudo apt-get install shc



echo "Usage
    shc -f script.sh -o binary
    shc -U -f script.sh -o binary # Untraceable binary (prevent strace, ptrace etc..)
"

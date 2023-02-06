################ set for post build script ################ 
## get console log from Jenkins
APIKEY=REMOVE_KEY

## get build result
curl -u $USER:$APIKEY --silent ${JOB_URL}${BUILD_ID}/consoleText -o console.log
#cat console.log |grep ERROR
#gawk 'NF > 0' console.log  |sed -n '310,331'p


## make report template and insert error message
cat > result.html << EOF
<!DOCTYPE html>
<html>
  <head>
    <title>New Page</title>
  </head>
  <body>
    <h1>Hello, World!</h1>
   ${ERROR}
  </body>
</html>

EOF

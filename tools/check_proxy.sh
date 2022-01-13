#!/bin/bash
# 
# Check the status of a proxy server by downloading a sample URL directly and through the proxy and then comparing the two files
# 
# -- Written 2008/03/13 TA


# establish the default settings
#
# this can be overridden on the command line, but as long as the Nagios instance is up, this URL should work
SAMPLE_URL=http://uptime.uhi.ac.uk/

# This is always overriden with a single host URL and is only provided as an example
HTTP_PROXY=http://squid2.uhi.ac.uk:8080/

# This needs to be high enough to weather network glitches, but not so high that we end up with multiple instances waiting to finish
TIMEOUT=30

# The default error code is unknown in case I haven't thought of something
ERROR_CODE=-1

# comment this out to see the output from wget on the command line (and in the cron output)
LOG="-o /dev/null"

# parse the command line options
#
if [ -z "$1" ]; then 
    echo "Usage: $0 PROXY_URL [TEST_URL] [TIMEOUT]";
    echo "  PROXY_URL: The full URL (including port number and protocol) of the proxy server to be tested";
    echo "  TEST_URL:  The URL to attempt to load";
    echo "  TIMEOUT:   The time (in seconds) to wait before giving up on loading the test URL";
    echo;
    exit $ERROR_CODE;
else
    HTTP_PROXY=$1
fi

if [ ! -z "$2" ]; then
    SAMPLE_URL=$2
fi

if [ ! -z "$3" ]; then
    TIMEOUT=$3
fi


# required binaries
#
WGET=/usr/bin/wget
DIFF=/usr/bin/diff
DATE=/bin/date
BC=/usr/bin/bc

# The base timestamp used to uniquely tag the filenames as a matching set
TIMESTAMP=`$DATE +%s%N`

# the filenames we will create
#
PROXIED_FILE="/tmp/proxied_$TIMESTAMP.html"
UNPROXIED_FILE="/tmp/unproxied_$TIMESTAMP.html"

# Remove the temporary files if they already exist
#
if [ -e $UNPROXIED_FILE ]; then rm $PROXIED_FILE; fi
if [ -e $PROXIED_FILE ]; then rm $PROXIED_FILE; fi

# Get the content directly
TIMESTAMP2=`$DATE +%s%N`
$WGET -t 1 --timeout=$TIMEOUT $SAMPLE_URL -O $UNPROXIED_FILE $LOG

# Get the content through the proxy
TIMESTAMP3=`$DATE +%s%N`
$WGET -t 1 --timeout=$TIMEOUT --proxy --execute=http_proxy=$HTTP_PROXY -O $PROXIED_FILE $SAMPLE_URL $LOG
TIMESTAMP4=`$DATE +%s%N`

# Compare the two files
DIFF_OUTPUT=`$DIFF $PROXIED_FILE $UNPROXIED_FILE`;

if [ ! -s "$UNPROXIED_FILE" ]; then
    echo "WARNING: The test URL does not appear to be available or is unreachable...";
    ERROR_CODE=1;
else 
    if [ -s "$UNPROXIED_FILE" -a ! -s "$PROXIED_FILE" ]; then
	echo "CRITICAL: Could not load the content through the specified proxy server..."
	ERROR_CODE=2;
    else 
	if [ ! -z "$DIFF_OUTPUT" ]; then 
	    echo "WARNING: The content downloaded through the proxy does not match the live content...";
	    ERROR_CODE=1;
	else 
	    DIRECT_TIME=`echo "scale=2; ($TIMESTAMP3-$TIMESTAMP2)/1000000000" | $BC`;
	    PROXIED_TIME=`echo "scale=2; ($TIMESTAMP4-$TIMESTAMP3)/1000000000" | $BC`;
	    ELAPSED_TIME=`echo "scale=2; ($TIMESTAMP4-$TIMESTAMP2)/1000000000" | $BC`;
	    echo "OK: Proxy server accessible and serving up the same content as a direct link.  Run completed in $ELAPSED_TIME seconds ($DIRECT_TIME direct access, $PROXIED_TIME proxied)...";

	    ERROR_CODE=0;
	fi
    fi
fi



#if [ -e $UNPROXIED_FILE ]; then rm $PROXIED_FILE; fi
#if [ -e $PROXIED_FILE ]; then rm $PROXIED_FILE; fi

exit $ERROR_CODE;

# Predefined exit codes for Nagios/NetSaint
#	UNKNOWN  = -1
#	OK       =  0
#	WARNING	 =  1
#	CRITICAL =  2

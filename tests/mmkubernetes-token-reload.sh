#!/bin/bash
# Verify mmkubernetes reloads the bearer token from tokenfile and retries once
# on an HTTP 401. See https://github.com/rsyslog/rsyslog for the module.
#
# The module reads the ServiceAccount token from tokenfile once at worker start
# and caches it in the curl Authorization header. On a short-lived projected
# token that is rotated on disk, the cached copy goes stale and every lookup
# 401s. This test rotates the token file after the worker has cached the old
# value, then confirms a subsequent (cache-miss) lookup 401s, reloads the fresh
# token, retries, and succeeds - so the record is still enriched.
#
# The kubernetes test server is run under "timeout" control so it is always
# terminated even if the script aborts (see mmkubernetes-basic.sh).
USE_VALGRIND=false
. ${srcdir:=.}/diag.sh init
check_command_available timeout
pwd=$( pwd )
k8s_srv_port=$( get_free_port )
generate_conf

# the token file the module reads and the server validates against; the worker
# caches its contents at startup and only re-reads it on reload
token_file=$RSYSLOG_DYNNAME.spool/sa-token
printf 'token-v1' > $token_file

add_conf '
global(workDirectory="'$RSYSLOG_DYNNAME.spool'")
module(load="../plugins/impstats/.libs/impstats" interval="1"
	   log.file="'"$RSYSLOG_DYNNAME.spool"'/mmkubernetes-stats.log" log.syslog="off" format="cee")
module(load="../plugins/imfile/.libs/imfile")
module(load="../plugins/mmjsonparse/.libs/mmjsonparse")
module(load="../contrib/mmkubernetes/.libs/mmkubernetes")

template(name="mmk8s_template" type="list") {
    property(name="$!all-json-plain")
    constant(value="\n")
}

input(type="imfile" file="'$RSYSLOG_DYNNAME.spool'/pod-*.log" tag="kubernetes" addmetadata="on")
action(type="mmjsonparse" cookie="")
action(type="mmkubernetes" busyretryinterval="1" tokenfile="'$pwd/$token_file'" tokenreloadinterval="0"
       kubernetesurl="http://localhost:'$k8s_srv_port'"
       filenamerules=["rule=:'$pwd/$RSYSLOG_DYNNAME.spool'/%pod_name:char-to:.%.%container_hash:char-to:_%_%namespace_name:char-to:_%_%container_name_and_id:char-to:.%.log",
	                  "rule=:'$pwd/$RSYSLOG_DYNNAME.spool'/%pod_name:char-to:_%_%namespace_name:char-to:_%_%container_name_and_id:char-to:.%.log"]
)
action(type="omfile" file=`echo $RSYSLOG_OUT_LOG` template="mmk8s_template")
'

testsrv=mmk8s-test-server
echo starting kubernetes \"emulator\"
# argv[4] enables bearer-token validation against $token_file (401 on mismatch)
timeout 2m $PYTHON -u $srcdir/mmkubernetes_test_server.py $k8s_srv_port ${RSYSLOG_DYNNAME}${testsrv}.pid ${RSYSLOG_DYNNAME}${testsrv}.started $pwd/$token_file > ${RSYSLOG_DYNNAME}.spool/mmk8s_srv.log 2>&1 &
BGPROCESS=$!
wait_process_startup ${RSYSLOG_DYNNAME}${testsrv} ${RSYSLOG_DYNNAME}${testsrv}.started
echo background mmkubernetes_test_server.py process id is $BGPROCESS

startup

# record 1: the token on disk (v1) matches - the worker caches v1 and the lookup
# succeeds normally. Draining the queue guarantees the worker has started and
# cached v1 *before* we rotate the token below.
cat > ${RSYSLOG_DYNNAME}.spool/pod-name1_namespace-name1_container-name1-id1.log <<EOF
{"log":"{\"message\":\"HEAD1 / 200 1ms - 9.0B\"}\n","stream":"stdout","time":"2018-04-06T17:26:34.492083106Z","testid":1}
EOF
wait_queueempty

# rotate the projected token on disk, as kubelet does at ~80% of its lifetime.
# The worker still holds the cached v1 in its curl header; the server now only
# accepts v2.
printf 'token-v2' > $token_file

# record 2: a new pod/namespace is a cache miss, so the worker queries the API
# with its stale cached v1 token -> 401 -> reload v2 from disk -> retry -> 200.
cat > ${RSYSLOG_DYNNAME}.spool/pod-name2_namespace-name2_container-name2-id2.log <<EOF
{"log":"{\"message\":\"HEAD2 / 200 1ms - 9.0B\"}\n","stream":"stdout","time":"2018-04-06T17:26:34.492083106Z","testid":2}
EOF
wait_queueempty

shutdown_when_empty
wait_shutdown
kill $BGPROCESS
wait_pid_termination ${RSYSLOG_DYNNAME}${testsrv}.pid

rc=0
# both records must be enriched with kubernetes metadata: record 1 under the
# original token, record 2 only after the token was reloaded on the 401
$PYTHON -c 'import sys,json
rc = 0
actual = {}
for line in open(sys.argv[1]):
	hsh = json.loads(line)
	if "testid" in hsh:
		actual[hsh["testid"]] = hsh
for testid, pod, ns in ((1, "pod-name1", "namespace-name1"), (2, "pod-name2", "namespace-name2")):
	if testid not in actual:
		print("Error: record for testid {0} not found in output".format(testid))
		rc = 1
		continue
	k8s = actual[testid].get("kubernetes", {})
	if k8s.get("pod_name") != pod or k8s.get("namespace_name") != ns:
		print("Error: record for testid {0} missing expected kubernetes metadata: {1}".format(
			testid, json.dumps(actual[testid])))
		rc = 1
sys.exit(rc)
' $RSYSLOG_OUT_LOG || rc=$?

# the reload-and-retry path must have fired for record 2
grep -q 'mmkubernetes: got \[401\].*reloaded SA token and retrying once' $RSYSLOG_OUT_LOG || \
	{ echo "fail: did not find token reload-and-retry log message"; rc=1; }
# and the retry must have recovered - no surfaced Unauthorized error
if grep -q 'mmkubernetes: Unauthorized' $RSYSLOG_OUT_LOG ; then
	echo "fail: unexpected Unauthorized error - reload did not recover the 401"
	rc=1
fi

if [ ${rc:-0} -ne 0 ]; then
	echo
	echo "FAIL: expected data not found.  $RSYSLOG_OUT_LOG is:"
	cat ${RSYSLOG_DYNNAME}.spool/mmk8s_srv.log
	cat $RSYSLOG_OUT_LOG
	error_exit 1
fi

exit_test

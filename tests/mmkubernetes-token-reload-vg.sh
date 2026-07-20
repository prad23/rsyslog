#!/bin/bash
# valgrind variant of mmkubernetes-token-reload.sh - see that script for details.
# Runs the same token reload-on-401 scenario under valgrind to catch leaks in
# the header rebuild / reload path.
USE_VALGRIND=true
. ${srcdir:=.}/diag.sh init
check_command_available timeout
pwd=$( pwd )
k8s_srv_port=$( get_free_port )
generate_conf

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
timeout 2m $PYTHON -u $srcdir/mmkubernetes_test_server.py $k8s_srv_port ${RSYSLOG_DYNNAME}${testsrv}.pid ${RSYSLOG_DYNNAME}${testsrv}.started $pwd/$token_file > ${RSYSLOG_DYNNAME}.spool/mmk8s_srv.log 2>&1 &
BGPROCESS=$!
wait_process_startup ${RSYSLOG_DYNNAME}${testsrv} ${RSYSLOG_DYNNAME}${testsrv}.started
echo background mmkubernetes_test_server.py process id is $BGPROCESS

export EXTRA_VALGRIND_SUPPRESSIONS="--suppressions=$srcdir/mmkubernetes.supp"
startup_vg

cat > ${RSYSLOG_DYNNAME}.spool/pod-name1_namespace-name1_container-name1-id1.log <<EOF
{"log":"{\"message\":\"HEAD1 / 200 1ms - 9.0B\"}\n","stream":"stdout","time":"2018-04-06T17:26:34.492083106Z","testid":1}
EOF
wait_queueempty

printf 'token-v2' > $token_file

cat > ${RSYSLOG_DYNNAME}.spool/pod-name2_namespace-name2_container-name2-id2.log <<EOF
{"log":"{\"message\":\"HEAD2 / 200 1ms - 9.0B\"}\n","stream":"stdout","time":"2018-04-06T17:26:34.492083106Z","testid":2}
EOF
wait_queueempty

shutdown_when_empty
wait_shutdown_vg
check_exit_vg
kill $BGPROCESS
wait_pid_termination ${RSYSLOG_DYNNAME}${testsrv}.pid

rc=0
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

grep -q 'mmkubernetes: got \[401\].*reloaded SA token and retrying once' $RSYSLOG_OUT_LOG || \
	{ echo "fail: did not find token reload-and-retry log message"; rc=1; }
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

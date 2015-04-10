#!/bin/bash

trap cleanup_and_exit SIGINT

declare BIN_PATH
declare PROV
declare TEST_TYPE="all"
declare SERVER
declare CLIENT
declare -i VERBOSE=0

# base ssh,  "short" and "long" timeout variants:
declare -r bssh="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 -o BatchMode=yes"
declare -r sssh="timeout 30s ${bssh}"
declare -r lssh="timeout 60s ${bssh}"
declare ssh=${sssh}

declare -r c_outp=$(mktemp)
declare -r s_outp=$(mktemp)

declare -i skip_count=0
declare -i pass_count=0
declare -i fail_count=0

simple_tests=(
	"cq_data"
	"dgram"
	"dgram_waitset"
	"msg"
	"msg_epoll"
	"poll"
	"rdm"
	"rdm_rma_simple"
	"rdm_shared_ctx"
	"rdm_tagged_search"
	"scalable_ep"
	"cmatose"
)

quick_tests=(
	"msg_pingpong -I 5"
	"msg_rma -o write -I 5"
	"msg_rma -o read -I 5"
	"msg_rma -o writedata -I 5"
	"rdm_atomic -I 5 -o all"
	"rdm_cntr_pingpong -I 5"
	"rdm_inject_pingpong -I 5"
	"rdm_multi_recv -I 5"
	"rdm_pingpong -I 5"
	"rdm_rma -o write -I 5"
	"rdm_rma -o read -I 5"
	"rdm_rma -o writedata -I 5"
	"rdm_tagged_pingpong -I 5"
	"ud_pingpong -I 5"
	"rc_pingpong -n 5"
)

standard_tests=(
	"msg_pingpong"
	"msg_rma -o write"
	"msg_rma -o read"
	"msg_rma -o writedata"
	"rdm_atomic -o all"
	"rdm_cntr_pingpong"
	"rdm_inject_pingpong"
	"rdm_multi_recv"
	"rdm_pingpong"
	"rdm_rma -o write"
	"rdm_rma -o read"
	"rdm_rma -o writedata"
	"rdm_tagged_pingpong"
	"ud_pingpong"
	"rc_pingpong"
)

unit_tests=(
	"av_test -d 192.168.10.1 -n 1"
	"dom_test -n 2"
	"eq_test"	
	"size_left_test"
)

all_tests=(
	"${unit_tests[@]}"
	"${simple_tests[@]}"
	"${standard_tests[@]}"
)

function errcho() {
	>&2 echo $*
}

function print_border {
	echo "# --------------------------------------------------------------"
}

# TODO: prefix with something, check for "" input
function print_results {
	#echo "$1" | sed ':a;N;$!ba;s/\n/\n  # /g'
	echo "$1" | sed 's/^/  # /g'
}

function cleanup {
	$ssh ${CLIENT} "ps -eo comm,pid | grep ^fi_ | awk '{print \$2}' | xargs -r kill -9" > /dev/null
	$ssh ${SERVER} "ps -eo comm,pid | grep ^fi_ | awk '{print \$2}' | xargs -r kill -9" > /dev/null
	rm -f $c_outp $s_outp
}

function cleanup_and_exit {
	cleanup
	exit 1
}

function unit_test {
	local test=$1
	local ret1=0
	local test_exe="fi_${test} -f $PROV"
	local SO=""

	${ssh} ${SERVER} ${BIN_PATH} "${test_exe}" &> $s_outp &
	p1=$!

	wait $p1
	ret1=$?

	SO=$(cat $s_outp)

	if [ "$ret1" == "61" ]; then
		printf "%-50s%10s\n" "$test_exe:" "Notrun"
		[ "$VERBOSE" -gt "1" ] && print_results "$SO"
		skip_count+=1
	
	elif [ "$ret1" != "0" ]; then
		if [ $ret1 == 124 ]; then
			cleanup
		fi
		printf "%-50s%10s\n" "$test_exe:" "Fail"
		[ "$VERBOSE" -gt "0" ] && print_results "$SO"
		fail_count+=1
	else
		printf "%-50s%10s\n" "$test_exe:" "Pass"
		[ "$VERBOSE" -gt "2" ] && print_results "$SO"
		pass_count+=1
	fi
}

function cs_test {
	local test=$1
	local ret1=0
	local ret2=0
	local test_exe="fi_${test} -f $PROV"
	local SO=""
	local CO=""

	${ssh} ${SERVER} ${BIN_PATH} "${test_exe} -s $SERVER" &> $s_outp &
	p1=$!
	sleep 1s

	${ssh} ${CLIENT} ${BIN_PATH} "${test_exe} $SERVER" &> $c_outp &
	p2=$!

	wait $p1
	ret1=$?

	wait $p2
	ret2=$?

	SO=$(cat $s_outp)
	CO=$(cat $c_outp)

	if [ "$ret1" == "61" -a "$ret2" == "61" ]; then
		printf "%-50s%10s\n" "$test_exe:" "Notrun"
		[ "$VERBOSE" -gt "1" ] && print_results "$SO" && print_results "$CO"
		skip_count+=1
	
	elif [ "$ret1" != "0" -o "$ret2" != "0" ]; then
		if [ $ret1 == 124 -o $ret2 == 124 ]; then
			cleanup
		fi
		printf "%-50s%10s\n" "$test_exe:" "Fail"
		[ "$VERBOSE" -gt "0" ] && print_results "$SO" && print_results "$CO"
		fail_count+=1
	else
		printf "%-50s%10s\n" "$test_exe:" "Pass"
		[ "$VERBOSE" -gt "2" ] && print_results "$SO" && print_results "$CO"
		pass_count+=1
	fi
}

function main {
	local -r tests=$(echo $1 | sed 's/all/unit,simple,quick,standard/' | tr ',' ' ')

	printf "# %-50s%10s\n" "Test" "Result"
	print_border

	for ts in ${tests}; do
	ssh=${lssh}
	case ${ts} in
		unit)
			ssh=${sssh}
			for test in "${unit_tests[@]}"; do
				unit_test "$test"
			done

		;;
		simple)
			for test in "${simple_tests[@]}"; do
				cs_test "$test"
			done
		;;
		quick)
			for test in "${quick_tests[@]}"; do
				cs_test "$test"
			done
		;;
		standard)
			for test in "${standard_tests[@]}"; do
				cs_test "$test"
			done
		;;
		*)
			errcho "Unknown test set: ${ts}"
			exit 1
		;;
	esac
	done

	total=$(( $pass_count + $fail_count ))

	print_border

	printf "# %-50s%10d\n" "Total Pass" $pass_count
	printf "# %-50s%10d\n" "Total Fail" $fail_count

	if [[ "$total" > "0" ]]; then
		printf "# %-50s%10d\n" "Percentage of Pass" $(( $pass_count * 100 / $total ))
	fi

	print_border

	cleanup
	exit $fail_count
}

function usage {
	errcho "Usage:"
	errcho "  $0 [OPTIONS] provider <host> <client>"
	errcho
	errcho "Run fabtests on given nodes, report pass/fail/notrun status."
	errcho
	errcho "Options:"
	errcho -e " -v..\tprint output of failing/notrun/passing"
	errcho -e " -t\ttest set(s): all,quick,unit,simple,standard (default all)"
	errcho -e " -p\tpath to test bins (default PATH)"
	exit 1
}

while getopts ":vt:p:" opt; do
case ${opt} in
	t) TEST_TYPE=$OPTARG
	;;
	v) VERBOSE+=1
	;;
	p) BIN_PATH="PATH=${OPTARG}:${PATH}"
	;;
	:|\?) usage
	;;
esac

done

# shift past options
shift $((OPTIND-1))

if [[ "$#" != "3" ]]; then
	usage
fi

PROV=$1
CLIENT=$2
SERVER=$3

main ${TEST_TYPE}

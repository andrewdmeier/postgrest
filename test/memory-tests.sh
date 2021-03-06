#! /usr/bin/env bash
currentTest=1
failedTests=0
result(){ echo "$1 $currentTest $2"; currentTest=$(( $currentTest + 1 )); }
ok(){ result 'ok' "- $1"; }
ko(){ result 'not ok' "- $1"; failedTests=$(( $failedTests + 1 )); }

pgrPort=49421

pgrStopAll(){ pkill -f "$(stack path --profile --local-install-root)/bin/postgrest"; }

pgrStart(){ stack exec --profile -- postgrest test/memory-tests/config +RTS -p -h >/dev/null & pgrPID="$!"; }
pgrStop(){ kill "$pgrPID" 2>/dev/null; }

setUp(){ pgrStopAll; }
cleanUp(){ pgrStopAll; }

checkPgrStarted(){
  while pgrStarted && test $(rootStatus) -ne 200
  do
    sleep 1
  done
}
pgrStarted(){ kill -0 "$pgrPID" 2>/dev/null; }
rootStatus(){
  curl -s -o /dev/null -I -w '%{http_code}' "http://localhost:$pgrPort/"
}

jsonKeyTest(){
  pgrStart
  checkPgrStarted
  factor=$(( 3*$(numfmt --from=si $1)/4 )) # 3/4 on $1 is need to maintain the specified size because of base64
  payload="{\"blob\" : \"$(dd if=/dev/zero bs=$factor count=1 status=none | base64)\"}"
  httpStatus=$(echo $payload | curl -s -H "Content-Type: application/json" --request $2 -d @- -w '%{http_code}' http://localhost:$pgrPort$3 | tr -d '"')
  if test "$httpStatus" -ge 200 && test "$httpStatus" -lt 210
  then
    pgrStop
    while [ ! -s postgrest.prof ]
    do
      sleep 1
    done
    BYTES_FMT=$(cat postgrest.prof | grep -o -P '(?<=alloc =).*(?=bytes)' | tr -d ' ')
    BYTES=$(echo $BYTES_FMT | tr -d ',')
    MAX_BYTES=$(numfmt --from=si $4)
    if test $BYTES -le $MAX_BYTES
    then
      ok "$2 $3: with a json key of $1 the memory usage($BYTES_FMT bytes) is less than $4"
    else
      ko "$2 $3: with a json key of $1 the memory usage($BYTES_FMT bytes) is more than $4"
    fi
  else
    pgrStop
    ko "$2 $3: request failed with http $httpStatus"
  fi
}

postJsonArrayTest(){
  pgrStart
  checkPgrStarted
  arr=()
  arr+=('[')
  for i in $(seq 1 $(expr $1 - 1))
  do
    arr+=("{\"id\": $i, \"body\": \"xxxxxxx\"},")
  done
  arr+=("{\"id\": $1, \"body\": \"xxxxxxx\"}")
  arr+=(']')
  payload=$(echo ${arr[*]})
  httpStatus=$(echo $payload | curl -s -H "Content-Type: application/json" -d @- -w '%{http_code}' http://localhost:$pgrPort$2 | tr -d '"')
  if test "$httpStatus" -ge 200 && test "$httpStatus" -lt 210
  then
    pgrStop
    while [ ! -s postgrest.prof ]
    do
      sleep 1
    done
    BYTES_FMT=$(cat postgrest.prof | grep -o -P '(?<=alloc =).*(?=bytes)' | tr -d ' ')
    BYTES=$(echo $BYTES_FMT | tr -d ',')
    MAX_BYTES=$(numfmt --from=si $3)
    PAYLOAD_SIZE=$(echo $payload | wc -c | numfmt --to=si)
    if test $BYTES -le $MAX_BYTES
    then
      ok "POST $2: with a json payload of $PAYLOAD_SIZE that has $1 array values the memory usage($BYTES_FMT bytes) is less than $3"
    else
      ko "POST $2: with a json payload of $PAYLOAD_SIZE that has $1 array values the memory usage($BYTES_FMT bytes) is more than $3"
    fi
  else
    pgrStop
    ko "POST $2: request failed with http $httpStatus"
  fi
}

setUp

echo "Running memory usage tests.."

jsonKeyTest "1M" "POST" "/rpc/leak?columns=blob" "12M"
jsonKeyTest "1M" "POST" "/leak?columns=blob" "12M"
jsonKeyTest "1M" "PATCH" "/leak?id=eq.1&columns=blob" "12M"

jsonKeyTest "10M" "POST" "/rpc/leak?columns=blob" "40M"
jsonKeyTest "10M" "POST" "/leak?columns=blob" "40M"
jsonKeyTest "10M" "PATCH" "/leak?id=eq.1&columns=blob" "40M"

jsonKeyTest "50M" "POST" "/rpc/leak?columns=blob" "170M"
jsonKeyTest "50M" "POST" "/leak?columns=blob" "170M"
jsonKeyTest "50M" "PATCH" "/leak?id=eq.1&columns=blob" "170M"

postJsonArrayTest "1000" "/perf_articles?columns=id,body" "10M"
postJsonArrayTest "10000" "/perf_articles?columns=id,body" "10M"
postJsonArrayTest "100000" "/perf_articles?columns=id,body" "20M"

cleanUp

exit $failedTests

#!/usr/bin/env bash

set -Eeo pipefail

dependencies=(awk curl date gzip jq)
for program in "${dependencies[@]}"; do
    command -v "$program" >/dev/null 2>&1 || {
        echo >&2 "Couldn't find dependency: $program. Aborting."
        exit 1
    }
done

if [[ "${RUNNING_IN_DOCKER}" ]]; then
    source "/app/datadis_exporter.conf"
elif [[ -f $CREDENTIALS_DIRECTORY/creds ]]; then
    # shellcheck source=/dev/null
    source "$CREDENTIALS_DIRECTORY/creds"
else
    source "./datadis_exporter.conf"
fi

[[ -z "${INFLUXDB_HOST}" ]] && echo >&2 "INFLUXDB_HOST is empty. Aborting" && exit 1
[[ -z "${INFLUXDB_API_TOKEN}" ]] && echo >&2 "INFLUXDB_API_TOKEN is empty. Aborting" && exit 1
[[ -z "${ORG}" ]] && echo >&2 "ORG is empty. Aborting" && exit 1
[[ -z "${BUCKET}" ]] && echo >&2 "BUCKET is empty. Aborting" && exit 1
[[ -z "${DATADIS_USERNAME}" ]] && echo >&2 "DATADIS_USERNAME is empty. Aborting" && exit 1
[[ -z "${DATADIS_PASSWORD}" ]] && echo >&2 "DATADIS_PASSWORD is empty. Aborting" && exit 1
[[ -z "${CUPS}" ]] && echo >&2 "CUPS is empty. Aborting" && exit 1
[[ -z "${DISTRIBUTOR_CODE}" ]] && echo >&2 "DISTRIBUTOR_CODE is empty. Aborting" && exit 1

AWK=$(command -v awk)
CURL=$(command -v curl)
DATE=$(command -v date)
GZIP=$(command -v gzip)
JQ=$(command -v jq)

TODAY=$($DATE +"%Y-%m-%d")
LAST_MONTH=$($DATE +"%Y-%m-%d" --date "1 month ago")
CURRENT_YEAR=$($DATE +"%Y")

INFLUXDB_URL="https://$INFLUXDB_HOST/api/v2/write?precision=s&org=$ORG&bucket=$BUCKET"
DATADIS_LOGIN_URL="https://datadis.es/nikola-auth/tokens/login"
DATADIS_SUPPLIES_API_URL="https://datadis.es/api-private/api/get-supplies"
DATADIS_CONTRACT_API_URL="https://datadis.es/api-private/api/get-contract-detail?cups=$CUPS&distributorCode=$DISTRIBUTOR_CODE"
DATADIS_CONSUMPTION_API_URL="https://datadis.es/api-private/api/get-consumption-data"
DATADIS_POWER_API_URL="https://datadis.es/api-private/api/get-max-power"

# Obtain token
datadis_token=$(
    $CURL --silent --fail --show-error \
        --request POST \
        --compressed \
        --data "username=$DATADIS_USERNAME" \
        --data "password=$DATADIS_PASSWORD" \
        "$DATADIS_LOGIN_URL"
)

# Fetch point type
datadis_point_type=$(
    $CURL --silent --fail --show-error \
        --compressed \
        --header "Accept: application/json" \
        --header 'Accept-Encoding: gzip, deflate, br' \
        --header "Authorization: Bearer $datadis_token" \
        "$DATADIS_SUPPLIES_API_URL" |
        $JQ '.[].pointType'
)

# Fetch contract details
datadis_contract=$(
	$CURL --silent --show-error --write-out 'HTTPSTATUS:%{http_code}' \
        --compressed \
        --header "Accept: application/json" \
        --header 'Accept-Encoding: br' \
        --header "Authorization: Bearer $datadis_token" \
        --header 'Content-Type: application/json' \
        --header 'User-Agent: Mozilla/5.0' \
        "$DATADIS_CONTRACT_API_URL"
)

# Make the API request using curl and jq for JSON processing
#!/bin/bash

# Variables

END_DATE=$(date -d "today" +%Y/%m)
START_DATE=$(date -d "1 month ago" +%Y/%m)


# Curl command to fetch data
datadis_json=$(
    curl --silent --show-error --write-out 'HTTPSTATUS:%{http_code}' \
        --compressed \
        --location \
        --header "Accept: application/json" \
        --header 'Accept-Encoding: gzip, deflate, br' \
        --header "Authorization: Bearer $datadis_token" \
        --header 'Content-Type: application/json' \
        --header 'User-Agent: Mozilla/5.0' \
        "$DATADIS_CONSUMPTION_API_URL?distributorCode=$DISTRIBUTOR_CODE&measurementType=0&cups=$CUPS&pointType=5&endDate=$END_DATE&startDate=$START_DATE" |
    jq '.response.timeCurveList'
)

# Print the JSON response
echo "$datadis_json"


# Extract the timeCurveList from the response using jq
timeCurveList=$(echo "$datadis_json" | $JQ '.response.timeCurveList')

consumption_stats=$(
    echo "$datadis_json" |
        $JQ --raw-output '
        (.[] |
        [env.CUPS,
        (.period | if . == "PUNTA" then "1" elif . == "LLANO" then "2" elif . == "VALLE" then "3" else empty end),
        .measureMagnitudeActive,
        ( (.date? + " " + ((if .hour == "24:00" then "00:00" else .hour end) | tostring)) | strptime("%Y/%m/%d %H:%M") | todate | fromdate)
        ])
        | @tsv' |
        $AWK '{printf "datadis_consumption,cups=%s,period=%s consumption=%s %s\n", $1, $2, $3, $4}'
)


datadis_power_json=$(
    curl --silent --show-error --write-out 'HTTPSTATUS:%{http_code}' \
        --compressed \
        --location \
        --header "Accept: application/json" \
        --header 'Accept-Encoding: gzip, deflate, br' \
        --header "Authorization: Bearer $datadis_token" \
        --header 'Content-Type: application/json' \
        --header 'User-Agent: Mozilla/5.0' \
        "$DATADIS_POWER_API_URL?distributorCode=$DISTRIBUTOR_CODE&cups=$CUPS&endDate=$END_DATE&startDate=$START_DATE" |
    jq '.response.timeCurveList'
)

power_stats=$(
    echo "$datadis_power_json" |
        $JQ --raw-output '
         (.[] |
         [env.CUPS,
         .date,
         .maxPower,
         ( (.date? + ((if .hour == "24:00" then "00:00" else .hour end) | tostring)) | strptime("%Y/%m/%d %H:%M") | todate | fromdate)
         ])
         | @tsv' |
        $AWK '{printf "datadis_power,cups=%s,period=%s max_power=%s %s\n", $1, $2, $3, $4}'
)

# Directory to store local exports
EXPORT_DIR="./exports"
mkdir -p "$EXPORT_DIR"

# Export data to local files
echo "$consumption_stats" > "$EXPORT_DIR/datadis_consumption_stats_$TODAY.tsv"
echo "$power_stats" > "$EXPORT_DIR/datadis_power_stats_$TODAY.tsv"

# Concatenate stats for InfluxDB
stats=$(
    cat <<END_HEREDOC
$consumption_stats
$power_stats
END_HEREDOC
)

# Send stats to InfluxDB
echo "${stats}" |
    $GZIP |
    $CURL --silent --fail --show-error \
        --request POST "${INFLUXDB_URL}" \
        --header 'Content-Encoding: gzip' \
        --header "Authorization: Token $INFLUXDB_API_TOKEN" \
        --header "Content-Type: text/plain; charset=utf-8" \
        --header "Accept: application/json" \
        --data-binary @-

echo "Data exported locally and sent to InfluxDB."

#!/usr/bin/env bash
# Simple script to look for Application Load Balancers (ALBs) that have had 0 requests in a given period
# This is only for ALBs, not Classic Load Balancers (CLBs), Network Load Balancers (NLBs), or Gateway Load Balancers (GLBs)
# Apache License, Version 2.0, January 2004
# Author: @jonzobrist / jon@jonzobrist.com/ zob@amazon.com
# Basic usage: ./find-unused-elbs.sh [EC2 region|all]
# Or that + days to look for data: ./find-unused-elbs.sh [EC2 region|all] <days>
# Or that + a profile to look for data: ./find-unused-elbs.sh [EC2 region|all] <days> <profile>
# Minimal is to say a specific EC2 region, e.g. us-east-1, but will also check all regions if you say 'all'

DEBUG() {
    # Debug function, the way I create these statements is take all of the print/echo statements from
    # writing and testing the script, and replace echo with DEBUG.  Then I can turn on/off debugging
    # by setting a value to DEBUG, like 'DEBUG=1; ./script.sh'
    if [ ! -z ${DEBUG} ]
     then
        echo "${@}" 1>&2
    fi
}

INFO() {
    # Info function, layer 2 of logging, this is for things that are important to the user, but not
    if [ ! -z ${INFO} ]
     then
        echo "${@}" 1>&2
    fi
}

cw_datetime() {
  # Return a CloudWatch friendly datetime $1 days ago, default 0 (now)
  UNAME=$(uname)
     if [ "${UNAME}" = "Darwin" ]
      then
         if [ ! -z ${1} ]
          then
            date -u -v-${1}d +%FT%H:00:00Z #Get the start time, round off min/seconds
         else
            date -u +%FT%H:00:00Z # NOW, rounding off min/seconds
         fi
      elif [ "${UNAME}" = "Linux" ]
       then
        if [ ! -z ${1} ]
        then
            date -d "${1} days ago" +%Y-%m-%dT%H:00:00Z
        else
            date +%Y-%m-%dT%H:00:00Z
       fi
     fi
}

setup() {
    DEBUG "Entering setup at $(date)"
    # Default period is 30 days, set DAYS_AGO in your env to override/change
    # Default region is us-east-1, set AWS_DEFAULT_REGION in your env to override/change
    # Settings will duplicate the input checks, this is intentional to use the functions independently of script
    DAYS_AGO=${DAYS_AGO:-30}
    PROFILE=${PROFILE:-default}
    REGION=${REGION:-us-east-1}
    PERIOD=$((${DAYS_AGO} * 86400)) # Convert days into seconds for CW
    START=$(cw_datetime ${DAYS_AGO}) #Get the start time, round off min/seconds
    END=$(cw_datetime) #Get the start time, round off min/seconds
    METRIC="RequestCount"
    STAT="Sum"
    OUTPUT_DIR="$(pwd)/output"
    ACTIVE_FILE="${OUTPUT_DIR}/ACTIVE-ALBs-${DAYS_AGO}-days-${REGION}.txt"
    INACTIVE_FILE="${OUTPUT_DIR}/INACTIVE-ALBs-${DAYS_AGO}-days-${REGION}.txt"
    REQUEST_COUNT_FILE="${OUTPUT_DIR}/REQUESTS-PER-ALBs-${DAYS_AGO}-days-${REGION}.txt"
    if [ ! -d ${OUTPUT_DIR} ]; then DEBUG "Making base dir ${OUTPUT_DIR} at $(date)"; mkdir -p ${OUTPUT_DIR}; else DEBUG "Base dir exists ${OUTPUT_DIR} at $(date)"; fi
    if [ -f ${INACTIVE_FILE} ]; then DEBUG "Cleaning up active file ${ACTIVE_FILE}"; /bin/rm ${INACTIVE_FILE}; fi; touch ${INACTIVE_FILE}
    if [ -f ${ACTIVE_FILE} ]; then DEBUG "Cleaning up active file ${ACTIVE_FILE}"; /bin/rm ${ACTIVE_FILE}; fi; touch ${ACTIVE_FILE}
    if [ -f ${REQUEST_COUNT_FILE} ]; then DEBUG "Cleaning up active file ${REQUEST_COUNT_FILE}"; /bin/rm ${REQUEST_COUNT_FILE}; fi; touch ${REQUEST_COUNT_FILE}
}

check_aws_env() {
    # actually setting defaults to avoid empty args in aws cli
    REGION=${REGION:-us-east-1}
    PROFILE=${PROFILE:-default}
    OUTPUT=${OUTPUT:-table}
    # Test AWS CLI, installed?
    DEBUG "Testing AWS CLI at $(date)"
    if ! command -v aws &> /dev/null
    then
        echo "AWS CLI could not be found, please install and configure:"
        echo "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        return 1
    fi
    # Do we have a valid profile?
    AWS_ACCOUNT=$(aws --region ${REGION} --profile ${PROFILE} sts get-caller-identity --query Account --output text)
    if [ $? -ne 0 ]; then
        echo "AWS CLI is not working, please ensure credentials are setup and working:"
        return 1
    else
        DEBUG "AWS CLI is working, account ${AWS_ACCOUNT} at $(date)"
    fi
}

aws_env() {
    # printing the values of common settings, for debugging
    echo "REGION=${REGION}"
    echo "PROFILE=${PROFILE}"
    echo "OUTPUT=${OUTPUT}"
}

alb_from_arn() {
    ALB_ARN=${ALB_ARN:-${1}}
    ALB=${ALB_ARN#*loadbalancer/}
    echo ${ALB}
}

get_elbs() {
    # using the AWS CLI, get the ARNs (or names for V1) for all our ELBs
    check_aws_env
    ELB_TYPE=${1:-alb}
    if [ ! -z ${DEBUG} ] && [ ! -z ${AWS_DEBUG} ]
     then
        # AWS_CLI_APPEND="${AWS_CLI_APPEND} --debug"
        AWS_CLI_APPEND="--debug"
    else
        AWS_CLI_APPEND=""
    fi
    case ${ELB_TYPE} in
        alb | ALB)
            DEBUG "aws --region ${REGION} --profile ${PROFILE} ${AWS_CLI_APPEND} elbv2 describe-load-balancers --query \"LoadBalancers[?Type == 'application'].LoadBalancerArn\" --output ${OUTPUT}"
            aws --region ${REGION} --profile ${PROFILE} ${AWS_CLI_APPEND} elbv2 describe-load-balancers --query "LoadBalancers[?Type == 'application'].LoadBalancerArn" --output ${OUTPUT}
        ;;
        nlb | NLB)
            DEBUG "aws --region ${REGION} --profile ${PROFILE} ${AWS_CLI_APPEND} elbv2 describe-load-balancers --query \"LoadBalancers[?Type == 'network'].LoadBalancerArn\" --output ${OUTPUT}"
            aws --region ${REGION} --profile ${PROFILE} ${AWS_CLI_APPEND} elbv2 describe-load-balancers --query "LoadBalancers[?Type == 'network'].LoadBalancerArn" --output ${OUTPUT}
        ;;
        clb | CLB)
            DEBUG "aws --region ${REGION} --profile ${PROFILE} elb describe-load-balancers --query \"LoadBalancerDescriptions[].[LoadBalancerName]\" --output ${OUTPUT}"
            aws --region ${REGION} --profile ${PROFILE} elb describe-load-balancers --query "LoadBalancerDescriptions[].[LoadBalancerName]" --output ${OUTPUT}
        ;;
        *)
            echo "Usage: get_elbs [alb|clb|nlb]"
        ;;
    esac
}

get_alb_arns() {
    DEBUG "Enter get_alb_arns, input 1 ${1} at $(date)"
    REGION=${1:-${REGION}}
    DEBUG "Set REGION to ${REGION} at $(date)"
    check_aws_env
    ORIG_OUTPUT="${OUTPUT}"
    OUTPUT="text"
    DEBUG "Getting ALB ARNs at $(date)"
    get_elbs alb | tr '\t' '\n'
    OUTPUT="${ORIG_OUTPUT}"
}

get_cw_metrics() {
    DEBUG "Enter get_cw_metrics, input 1 is ${1} at $(date)"
    # AWS CloudWatch CLI call for get-metric-statistics
    # Required: --namespace --metric-name --start-time --end-time --period
    # Options: --dimensions ? is this a filter?
    ALB_ARN=${1:-${ALB_ARN}}
    PRE_OUTPUT=${OUTPUT:-text}
    ORIG_OUTPUT=${OUTPUT}
    OUTPUT="text"
    FROM_ARN=$(alb_from_arn ${ALB_ARN})
    ALB=${ALB:-${FROM_ARN}} #If we have an ALB, prefer it, otherwise use one from the ARN
    DEBUG "ALB ${ALB} from ARN ${ALB_ARN}"
    CW_DIMENSIONS="Name=LoadBalancer,Value=${ALB}"
    DEBUG "CW_DIMENSIONS = ${CW_DIMENSIONS}"
    DEBUG "aws --region ${REGION} --profile ${PROFILE} cloudwatch  get-metric-statistics --namespace AWS/ApplicationELB --metric-name ${METRIC} --start ${START} --end-time ${END} --period ${PERIOD} --statistics ${STAT} --dimensions ${CW_DIMENSIONS} --query \"Datapoints[].Sum\" --output ${OUTPUT}"
    # The line below uses paste and BC to get the sum of the datapoints, if there are more than 1
    # I think it will not be needed, as we have the period in days and seconds of metric length is equal
    # to the period, so we should only get one datapoint per call to CloudWatch API.
    # But, if you see errors due to more datapoints, swap back to it, and let me know.
    # REQUEST_COUNT=$(aws --region ${REGION} --profile ${PROFILE} cloudwatch  get-metric-statistics --namespace AWS/ApplicationELB --metric-name ${METRIC} --start ${START} --end-time ${END} --period ${PERIOD} --statistics ${STAT} --dimensions ${CW_DIMENSIONS} --query "Datapoints[].Sum" --output ${OUTPUT} | paste -s -d '+' - | bc)
    REQUEST_COUNT=$(aws --region ${REGION} --profile ${PROFILE} cloudwatch  get-metric-statistics --namespace AWS/ApplicationELB --metric-name ${METRIC} --start ${START} --end-time ${END} --period ${PERIOD} --statistics ${STAT} --dimensions ${CW_DIMENSIONS} --query "Datapoints[].Sum" --output ${OUTPUT})
    OUTPUT=${ORIG_OUTPUT}
    printf "%.0f\n" ${REQUEST_COUNT}
}

find_unused_elbs_in_region() {
    check_aws_env
    declare -x ELB_COUNT=0
    declare -x INACTIVE_ELB_COUNT=0
    declare -x ACTIVE_ELB_COUNT=0
    # ELB_COUNT=0; export ELB_COUNT
    # INACTIVE_ELB_COUNT=0; export INACTIVE_ELB_COUNT
    # ACTIVE_ELB_COUNT=0; export ACTIVE_ELB_COUNT
    for ALB_ARN in $(get_alb_arns ${REGION}); do
        DEBUG "Checking ${ALB_ARN}"
        let $((ELB_COUNT++))
        DEBUG "ELBs checked: ${ELB_COUNT}, Inactive: ${INACTIVE_ELB_COUNT}, Active: ${ACTIVE_ELB_COUNT} at $(date)"
        REQUEST_COUNT=$(get_cw_metrics ${ALB_ARN})
        DEBUG "${ALB_ARN} has ${REQUEST_COUNT} requests in the last ${DAYS_AGO} days"
        echo "${ALB_ARN},${REQUEST_COUNT},${DAYS_AGO},${REGION}" >> ${REQUEST_COUNT_FILE}
        if [ ! ${REQUEST_COUNT} -eq 0 ]
         then
            let $((ACTIVE_ELB_COUNT++))
            echo -n "+"
            INFO "${ALB_ARN} had ${REQUEST_COUNT} requests in the past ${DAYS_AGO} days"
            echo "${ALB_ARN}" >> ${ACTIVE_FILE}
        else
            let $((INACTIVE_ELB_COUNT++))
            echo -n "-"
            INFO "${ALB_ARN} had 0 traffic in the past ${DAYS_AGO} days"
            echo "${ALB_ARN}" >> ${INACTIVE_FILE}
        fi
    done
    if [ ${ELB_COUNT} -eq 0 ]
     then
        echo "No ELBs found in ${REGION}"
    else
        echo "Found ${ELB_COUNT} ELBs in ${REGION}"
        echo "Found ${ACTIVE_ELB_COUNT} active ELBs in ${REGION} (in file ${ACTIVE_FILE})"
        echo "Found ${INACTIVE_ELB_COUNT} inactive ELBs in ${REGION} (in file ${INACTIVE_FILE})"
    fi
    DEBUG "${ELB_COUNT} ELBs in ${REGION}"
    DEBUG "${ACTIVE_ELB_COUNT} active ELBs in ${REGION} (in file ${ACTIVE_FILE})"
    DEBUG "${INACTIVE_ELB_COUNT} inactive ELBs in ${REGION} (in file ${INACTIVE_FILE})"
}


# # Startup check for input, give usage if none
if [ ! -z ${1} ]
 then
    REGION=${1}
    DAYS_AGO=${2:-30}
    PROFILE=${3:-default}
    setup
    case ${REGION} in
        af-south-1|ap-east-1|ap-northeast-1|ap-northeast-2|ap-northeast-3|ap-south-1|ap-southeast-1|ap-southeast-2|ca-central-1|cn-north-1|cn-northwest-1|eu-central-1|eu-north-1|eu-south-1|eu-west-1|eu-west-2|eu-west-3|me-south-1|sa-east-1|us-east-1|us-east-2|us-west-1|us-west-2|us-gov-west-1|us-gov-east-1)
            find_unused_elbs_in_region ${REGION}
            ;;
        all)
            for region in $(get_regions)
            do
                find_unused_elbs_in_region ${region} &
                sleep 15
            done
            ;;
        *)
            echo "Usage: ${0} region days_ago profile"
            ;;
    esac
 else
    echo "Usage: ${0} region days_ago profile"
fi

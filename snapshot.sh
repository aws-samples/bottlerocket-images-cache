# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#!/bin/bash
set -e

function print_help {
    echo "usage: $0 [options] <comma seperated container images>"
    echo "Build EBS snapshot for Bottlerocket data volume with cached container images"
    echo "Options:"
    echo "-h,--help Print this help"
    echo "-r,--region Set AWS region to build the EBS snapshot, (default: use environment variable of AWS_DEFAULT_REGION or IMDS)"
    echo "-a,--ami Set SSM Parameter path for Bottlerocket ID, (default: /aws/service/bottlerocket/aws-k8s-1.27/x86_64/latest/image_id)"
    echo "-i,--instance-type Set EC2 instance type to build this snapshot, (default: m5.large)"
    echo "-R,--instance-role Name of existing IAM role for created EC2 instance, (default: Create on launching)"
    echo "-q,--quiet Suppress all outputs and output generated snapshot ID only (default: false)"
}

QUIET=false

function log() {
    if [ "$QUIET" = false ]; then
        datestring=`date +"%Y-%m-%d %H:%M:%S"`
        echo -e "$datestring I - $@"
    fi
}

function logerror() {
    datestring=`date +"%Y-%m-%d %H:%M:%S"`
    echo -e "$datestring E - $@" 1>&2;
}

function cleanup() {
    aws cloudformation delete-stack --stack-name "Bottlerocket-ebs-snapshot"
    log "Stack deleted."
}

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        -r|--region)
            AWS_DEFAULT_REGION=$2
            shift
            shift
            ;;
        -a|--ami)
            AMI_ID=$2
            shift
            shift
            ;;
        -i|--instance-type)
            INSTANCE_TYPE=$2
            shift
            shift
            ;;
        -R|--instance-role)
            INSTANCE_ROLE=$2
            shift
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
IMAGES="$1"
set -u

AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')}
AMI_ID=${AMI_ID:-/aws/service/bottlerocket/aws-k8s-1.27/x86_64/latest/image_id}
INSTANCE_TYPE=${INSTANCE_TYPE:-m5.large}
INSTANCE_ROLE=${INSTANCE_ROLE:-NONE}
CTR_CMD="apiclient exec admin sheltie ctr -a /run/containerd/containerd.sock -n k8s.io"

if [ -z "${AWS_DEFAULT_REGION}" ]; then
    logerror "Please set AWS region"
    exit 1
fi

if [ -z "${IMAGES}" ]; then
    logerror "Please set images list"
    exit 1
fi

IMAGES_LIST=(`echo $IMAGES | sed 's/,/\n/g'`)
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}

##############################################################################################
export AWS_PAGER=""

# launch EC2
log "[1/8] Deploying EC2 CFN stack ..."
CFN_STACK_NAME="Bottlerocket-ebs-snapshot"
aws cloudformation deploy --stack-name $CFN_STACK_NAME --template-file ebs-snapshot-instance.yaml --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides AmiID=$AMI_ID InstanceType=$INSTANCE_TYPE InstanceRole=$INSTANCE_ROLE > /dev/null
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name $CFN_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

# wait for SSM ready
log  "[2/8] Launching SSM ."
while [[ $(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query "InstanceInformationList[0].PingStatus" --output text) != "Online" ]]
do
   sleep 5
done
log "SSM launched in instance $INSTANCE_ID."

# stop kubelet.service
log "[3/8] Stopping kubelet.service .."
CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" --comment "Stop kubelet" \
    --parameters commands="apiclient exec admin sheltie systemctl stop kubelet" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null
log "Kubelet service stopped."

# cleanup existing images
log "[4/8] Cleanup existing images .."
CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
    --document-name "AWS-RunShellScript" --comment "Cleanup existing images" \
    --parameters commands="$CTR_CMD images rm \$($CTR_CMD images ls -q)" \
    --query "Command.CommandId" --output text)
aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID > /dev/null
log "Existing images cleaned"

# pull images
log "[5/8] Pulling images:"
for IMG in "${IMAGES_LIST[@]}"
do
    ECR_REGION=$(echo $IMG | sed -n "s/^[0-9]*\.dkr\.ecr\.\([a-z1-9-]*\)\.amazonaws\.com.*$/\1/p")
    [ ! -z "$ECR_REGION" ] && ECRPWD="--u AWS:"$(aws ecr get-login-password --region $ECR_REGION) || ECRPWD=""
    for PLATFORM in amd64 arm64
    do
        log "Pulling $IMG - $PLATFORM ... "
        COMMAND="$CTR_CMD images pull --label io.cri-containerd.image=managed --platform $PLATFORM $IMG $ECRPWD "
        #echo $COMMAND
        CMDID=$(aws ssm send-command --instance-ids $INSTANCE_ID \
            --document-name "AWS-RunShellScript" --comment "Pull Images" \
            --parameters commands="$COMMAND" \
            --query "Command.CommandId" --output text)
        until aws ssm wait command-executed --command-id "$CMDID" --instance-id $INSTANCE_ID &> /dev/null && log "$IMG - $PLATFORM pulled. "
        do
            sleep 5
            if [ "$(aws ssm get-command-invocation --command-id $CMDID --instance-id $INSTANCE_ID --output text --query Status)" == "Failed" ]; then
                REASON=$(aws ssm get-command-invocation --command-id $CMDID --instance-id $INSTANCE_ID --output text --query StandardOutputContent)
                logerror "Image $IMG pulling failed with following output: "
                logerror $REASON
                cleanup
                exit 1
            fi
        done
    done
done


# stop EC2
log "[6/8] Stopping instance ... "
aws ec2 stop-instances --instance-ids $INSTANCE_ID --output text > /dev/null
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" > /dev/null && log "Instance $INSTANCE_ID stopped"

# create EBS snapshot
log "[7/8] Creating snapshot ... "
DATA_VOLUME_ID=$(aws ec2 describe-instances  --instance-id $INSTANCE_ID --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvdb'].Ebs.VolumeId" --output text)
SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $DATA_VOLUME_ID --description "Bottlerocket Data Volume snapshot" --query "SnapshotId" --output text)
until aws ec2 wait snapshot-completed --snapshot-ids "$SNAPSHOT_ID" &> /dev/null && log "Snapshot $SNAPSHOT_ID generated."
do
    sleep 5
done

# destroy temporary instance
log "[8/8] Cleanup."
cleanup

# done!
log "--------------------------------------------------"
log "All done! Created snapshot in $AWS_DEFAULT_REGION: $SNAPSHOT_ID"
if [ $QUIET = true ]; then
    echo "$SNAPSHOT_ID"
fi